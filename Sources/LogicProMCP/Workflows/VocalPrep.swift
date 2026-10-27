import Accelerate
import AVFoundation
import CryptoKit
import Foundation

/// `tracks.prepare_vocal`, the parts that need no Logic: frame features of an audio file, the
/// silence/breath analysis, the cut plan for one track's regions, and the region file offsets
/// read from `ProjectData`.
///
/// Measured on a real lead vocal (Logic 12.4, 48 kHz takes, 70 BPM) against a listener's notes:
/// every threshold is relative to the file's own noise floor (10th percentile of 10 ms frame
/// levels) and its sung level (median of clearly voiced frames), so nothing is tuned to one
/// recording level. A breath is a noise-like run (no periodicity, spectral centroid 1–4.5 kHz),
/// clearly quieter than singing, 0.18–1 s long, next to silence or very quiet; a short noise that
/// runs straight into a vowel without a dip is an "h"/consonant, not a breath.
enum VocalPrep {
    static let hop = 0.01

    // MARK: - Features

    struct Frames: Equatable, Sendable {
        var db: [Double]
        var periodicity: [Double]
        var centroid: [Double]
        var floor: Double
        var voicedMedian: Double
    }

    /// 1024-sample windows every 10 ms: level (dBFS of the mean square), the normalised
    /// autocorrelation peak for 60–1000 Hz (periodicity), and the spectral centroid.
    static func frames(samples x: [Float], sampleRate sr: Double) -> Frames? {
        let win = 1024, hopSamples = Int(sr * hop)
        guard hopSamples > 0, x.count >= win else { return nil }
        let log2n = vDSP_Length(10)
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fft) }
        var hann = [Float](repeating: 0, count: win)
        vDSP_hann_window(&hann, vDSP_Length(win), Int32(vDSP_HANN_NORM))
        let minLag = max(1, Int(sr / 1000)), maxLag = min(Int(sr / 60), win / 2)
        var db: [Double] = [], per: [Double] = [], cent: [Double] = []
        var windowed = [Float](repeating: 0, count: win)
        var re = [Float](repeating: 0, count: win / 2), im = [Float](repeating: 0, count: win / 2)
        var mag = [Float](repeating: 0, count: win / 2)
        let binHz = Float(sr) / Float(win)
        x.withUnsafeBufferPointer { all in
            var i = 0
            while i + win <= all.count {
                let seg = all.baseAddress! + i
                var ms: Float = 0
                vDSP_measqv(seg, 1, &ms, vDSP_Length(win))
                db.append(Double(10 * log10(ms + 1e-12)))
                var best: Float = 0
                for lag in minLag...maxLag {
                    let n = vDSP_Length(win - lag)
                    var dot: Float = 0, e1: Float = 0, e2: Float = 0
                    vDSP_dotpr(seg, 1, seg + lag, 1, &dot, n)
                    vDSP_svesq(seg + lag, 1, &e1, n)
                    vDSP_svesq(seg, 1, &e2, n)
                    let r = dot / (sqrt(e1 * e2) + 1e-9)
                    if r > best { best = r }
                }
                per.append(Double(best))
                vDSP_vmul(seg, 1, hann, 1, &windowed, 1, vDSP_Length(win))
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        windowed.withUnsafeBufferPointer { wp in
                            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: win / 2) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(win / 2))
                            }
                        }
                        vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(win / 2))
                    }
                }
                var num: Float = 0, den: Float = 0
                for k in 1..<(win / 2) { num += Float(k) * binHz * mag[k]; den += mag[k] }
                cent.append(Double(num / (den + 1e-20)))
                i += hopSamples
            }
        }
        let sorted = db.sorted()
        let floor = sorted[Int(Double(sorted.count) * 0.10)]
        let voiced = zip(db, per).filter { $0.1 > 0.75 && $0.0 > floor + 20 }.map(\.0).sorted()
        let voicedMedian = voiced.isEmpty ? floor + 30 : voiced[voiced.count / 2]
        return Frames(db: db, periodicity: per, centroid: cent, floor: floor, voicedMedian: voicedMedian)
    }

    /// The first channel of an audio file, with its own sample rate.
    static func readMono(_ url: URL) -> (samples: [Float], sampleRate: Double)? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0] else { return nil }
        return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), file.processingFormat.sampleRate)
    }

    // MARK: - Analysis

    struct Breath: Equatable, Sendable {
        var start: Double
        var end: Double
        var peakDB: Double
        var confident: Bool
    }

    struct Analysis: Equatable, Sendable {
        /// Sound to keep, in file seconds (silences of at least `minSilence` removed).
        var keep: [ClosedRange<Double>]
        var breaths: [Breath]
        /// 50 ms power-smoothed level per frame.
        var smoothed: [Double]
        var floor: Double
    }

    private enum FrameClass { case voiced, noise, quiet }

    private static func runs<T: Equatable>(_ values: [T]) -> [(value: T, start: Int, end: Int)] {
        var out: [(value: T, start: Int, end: Int)] = []
        for (i, v) in values.enumerated() {
            if let last = out.last, last.value == v { out[out.count - 1].end = i + 1 } else { out.append((v, i, i + 1)) }
        }
        return out
    }

    static func analyse(_ f: Frames, minSilence: Double = 1.0) -> Analysis {
        let n = f.db.count
        let pw = f.db.map { pow(10, $0 / 10) }
        let sdb: [Double] = (0..<n).map { i in
            let lo = max(0, i - 2), hi = min(n, i + 3)
            return 10 * log10(pw[lo..<hi].reduce(0, +) / Double(hi - lo))
        }
        // Voiced must be clearly louder than a breath, so hum on a quiet breath is not singing.
        var cls: [FrameClass] = (0..<n).map { i in
            if f.db[i] > max(f.floor + 15, f.voicedMedian - 20) && f.periodicity[i] > 0.6 { return .voiced }
            if f.db[i] > f.floor + 4 && f.centroid[i] > 900 { return .noise }
            return .quiet
        }
        var changed = true
        while changed {
            changed = false
            let rs = runs(cls)
            for (k, r) in rs.enumerated() where r.end - r.start < 3 && rs.count > 1 {
                let replacement = k > 0 ? rs[k - 1].value : rs[k + 1].value
                for i in r.start..<r.end { cls[i] = replacement }
                changed = true
                break
            }
        }
        let rs = runs(cls)
        var breaths: [Breath] = []
        for (k, r) in rs.enumerated() where r.value == .noise && (15...100).contains(r.end - r.start) {
            let a = r.start, b = r.end
            let weight = pw[a..<b].reduce(0, +)
            let meanCentroid = (a..<b).reduce(0.0) { $0 + f.centroid[$1] * pw[$1] } / weight
            let peak = f.db[a..<b].max()!
            guard (1000...4500).contains(meanCentroid), peak <= f.voicedMedian - 12 else { continue }
            let prev = k > 0 ? rs[k - 1].value : .quiet
            let next = k + 1 < rs.count ? rs[k + 1].value : .quiet
            // The start walks back through the breath's quiet rise.
            var s = a
            while s > 0, cls[s - 1] != .voiced, sdb[s - 1] > f.floor + 3, a - s < 30 { s -= 1 }
            let start = max(0, Double(s) * hop - (prev != .voiced ? 0.04 : 0))
            let voicedAfter = (b..<min(n, b + 30)).first { cls[$0] == .voiced } ?? n
            let end = next == .voiced ? Double(b) * hop : Double(min(b + 5, voicedAfter)) * hop
            var hLike = false
            if next == .voiced, b - a < 25 {
                let tail = f.db[max(a, b - 4)..<b].max()!
                let dip = f.db[max(0, b - 2)..<min(n, b + 3)].min()!
                hLike = tail >= peak - 1.5 && dip > tail - 4
            }
            let quietContext = prev == .quiet || next == .quiet
            let confident = (quietContext || peak <= f.voicedMedian - 18) && !hLike && b - a >= 18
            breaths.append(Breath(start: start, end: end, peakDB: peak, confident: confident))
        }
        // Sound = above floor + 10 dB, or a breath; silences of at least `minSilence` are removed.
        var active = sdb.map { $0 > f.floor + 10 }
        for br in breaths {
            for i in max(0, Int(br.start / hop))..<min(n, Int(br.end / hop) + 1) { active[i] = true }
        }
        for r in runs(active) where r.value && r.end - r.start < 8 && r.start > 0 && r.end < n {
            for i in r.start..<r.end { active[i] = false }
        }
        var spans: [(Int, Int)] = []
        var current: (Int, Int)?
        for r in runs(active) {
            if r.value {
                current = current.map { ($0.0, r.end) } ?? (r.start, r.end)
            } else if Double(r.end - r.start) * hop >= minSilence, let c = current {
                spans.append(c); current = nil
            }
        }
        if let current { spans.append(current) }
        func tail(_ b: Int) -> Int {
            var j = b, lo = sdb[min(b, n - 1)]
            while j + 1 < n, j - b < 30, sdb[j + 1] <= lo + 2, sdb[j + 1] > f.floor + 4 { j += 1; lo = min(lo, sdb[j]) }
            return j
        }
        let keep = spans.map { max(0, Double($0.0) * hop - 0.06)...(Double(tail($0.1)) * hop + 0.05) }
        return Analysis(keep: keep, breaths: breaths, smoothed: sdb, floor: f.floor)
    }

    // MARK: - Plan

    /// One region of the track as read from Logic, with where its audio comes from.
    struct Region: Equatable, Sendable {
        var name: String
        /// Project seconds.
        var start: Double
        var end: Double
        /// Audio file name in the project's `Media/Audio Files`.
        var file: String
        /// Project seconds minus file seconds: constant across one region's audio.
        var offset: Double
    }

    enum PieceKind: String, Sendable, Codable { case sound, breath }

    struct Piece: Equatable, Sendable, Codable {
        var start: Double
        var end: Double
        var kind: PieceKind
        var group: Int
    }

    struct Group: Equatable, Sendable, Codable {
        var file: String
        var offset: Double
        /// Project seconds of the regions as read, and as planned.
        var oldStart: Double, oldEnd: Double
        var newStart: Double, newEnd: Double
    }

    struct Plan: Equatable, Sendable, Codable {
        var groups: [Group]
        var pieces: [Piece]
        /// Breaths found but too uncertain to mark, in project seconds.
        var uncertainBreaths: [ClosedRange<Double>]
        var cuts: [Double] { Array(Set(pieces.flatMap { [round4($0.start), round4($0.end)] })).sorted() }
        var hash: String {
            let text = pieces.map { "\($0.group):\(round4($0.start)):\(round4($0.end)):\($0.kind.rawValue)" }.joined(separator: "|")
                + "#" + groups.map { "\($0.file)@\(round4($0.offset))" }.joined(separator: "|")
            return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func round4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }

    /// Consecutive regions playing one continuous stretch of one file (same file, same offset)
    /// form a group; a group's edges are where the take or the edit changes.
    static func groups(_ regions: [Region]) -> [[Region]] {
        var out: [[Region]] = []
        for r in regions.sorted(by: { $0.start < $1.start }) {
            if let last = out.last?.last, last.file == r.file, abs(last.offset - r.offset) < 0.003 {
                out[out.count - 1].append(r)
            } else {
                out.append([r])
            }
        }
        return out
    }

    static func plan(regions: [Region], analyses: [String: Analysis]) -> Plan? {
        let grouped = groups(regions)
        var groupsOut: [Group] = []
        for g in grouped {
            guard let a = analyses[g[0].file] else { return nil }
            let c = g[0].offset
            let oldStart = g[0].start - c, oldEnd = g.map(\.end).max()! - c
            let sdb = a.smoothed, n = sdb.count
            func quiet(_ t0: Double, _ t1: Double) -> Bool {
                let lo = max(0, Int(t0 * 100)), hi = min(n, Int(t1 * 100))
                return lo >= hi || sdb[lo..<hi].allSatisfy { $0 < a.floor + 15 }
            }
            // A breath right before the edit (only silence between) belongs to the phrase.
            var start = oldStart
            let before = a.breaths.filter { b in
                b.confident && b.start < oldStart && b.end <= oldStart + 0.05
                    && (oldStart - b.end <= 0.10 || (oldStart - b.end <= 0.4 && quiet(b.end, oldStart - 0.02)))
            }
            if let earliest = before.map(\.start).min() { start = earliest }
            // A region that stops while its note is still clearly sounding follows the decay (at
            // most 0.6 s); one that already ends in the decay's tail stays, so a re-run is stable.
            var end = oldEnd
            let i = min(n - 1, Int(oldEnd * 100))
            var j = i, lo = sdb[i]
            while sdb[i] > a.floor + 15, j < min(n - 1, i + 60), sdb[j + 1] <= lo + 3, sdb[j + 1] > a.floor + 5 { j += 1; lo = min(lo, sdb[j]) }
            if j > i { end = min(Double(j) * hop + 0.10, oldEnd + 0.6) }
            groupsOut.append(Group(file: g[0].file, offset: c, oldStart: oldStart + c, oldEnd: oldEnd + c,
                                   newStart: start + c, newEnd: end + c))
        }
        // Neighbouring groups never overlap: a later group's start wins over an earlier tail.
        for k in groupsOut.indices.dropFirst() {
            let prevEnd = groupsOut[k - 1].newEnd
            if groupsOut[k].newStart < prevEnd {
                groupsOut[k].newStart = max(groupsOut[k].newStart, min(prevEnd, groupsOut[k].oldStart))
                groupsOut[k - 1].newEnd = min(prevEnd, groupsOut[k].newStart)
            }
        }
        var pieces: [Piece] = []
        var uncertain: [ClosedRange<Double>] = []
        for (gi, g) in groupsOut.enumerated() {
            let a = analyses[g.file]!, c = g.offset
            let ws = g.newStart - c, we = g.newEnd - c
            var keep: [(Double, Double)] = a.keep.compactMap { k in
                let s = max(k.lowerBound, ws), e = min(k.upperBound, we)
                return e - s > 0.12 ? (s, e) : nil
            }
            var marked: [(Double, Double)] = []
            for b in a.breaths where b.end > ws + 0.05 && b.end <= we {
                let s = max(b.start, ws)
                if b.confident { marked.append((s, b.end)) } else { uncertain.append((s + c)...(b.end + c)) }
            }
            // A breath reaching in front of a sound piece starts that piece.
            for (bs, be) in marked {
                for k in keep.indices where keep[k].0 <= be && bs < keep[k].0 { keep[k].0 = bs }
            }
            // A piece starting just after the group's (planned) start starts with it.
            for k in keep.indices where keep[k].0 - ws > 0 && keep[k].0 - ws < 0.2 { keep[k].0 = ws }
            for k in marked.indices where marked[k].0 - ws > 0 && marked[k].0 - ws < 0.2 { marked[k].0 = ws }
            for (ks, ke) in keep {
                var cursor = ks
                for (bs, be) in marked.sorted(by: { $0.0 < $1.0 }) where bs >= ks - 0.001 && be <= ke + 0.001 {
                    if bs - cursor > 0.003 { pieces.append(Piece(start: cursor + c, end: bs + c, kind: .sound, group: gi)) }
                    pieces.append(Piece(start: max(bs, cursor) + c, end: be + c, kind: .breath, group: gi))
                    cursor = be
                }
                if ke - cursor > 0.003 { pieces.append(Piece(start: cursor + c, end: ke + c, kind: .sound, group: gi)) }
            }
        }
        return Plan(groups: groupsOut, pieces: pieces.sorted { $0.start < $1.start }, uncertainBreaths: uncertain)
    }

    // MARK: - Region file offsets from ProjectData

    /// Measured on Logic 12.4: a region record carries its start inside the audio file, in the
    /// file's samples, as a little-endian UInt32 70 bytes before the region's name. Only a name
    /// that occurs exactly once is read; the caller cross-checks the offsets of one take against
    /// each other before trusting them.
    static let regionOffsetDistance = 70

    enum OffsetRead: Equatable, Sendable { case found(UInt32), absent, ambiguous(Int) }

    static func regionFileOffset(name: String, projectData: Data) -> OffsetRead {
        let needle = Data(name.utf8)
        var hits: [Int] = []
        var from = projectData.startIndex
        while let r = projectData.range(of: needle, in: from..<projectData.endIndex) {
            // The name must end there (not be the prefix of a longer name such as "Voc #07.1").
            let after = r.upperBound < projectData.endIndex ? projectData[r.upperBound] : 0
            if after < 0x20 { hits.append(r.lowerBound) }
            from = r.lowerBound + 1
        }
        guard hits.count == 1 else { return hits.isEmpty ? .absent : .ambiguous(hits.count) }
        let at = hits[0] - regionOffsetDistance
        guard at >= projectData.startIndex else { return .absent }
        let bytes = projectData[at..<(at + 4)]
        return .found(bytes.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    /// The audio file a region plays, from its name: Logic names a recorded region after its file
    /// and appends ".N" per split ("Voc #07" → "Voc #07.1.03"). Returns the candidates to try.
    static func fileStemCandidates(regionName: String) -> [String] {
        var stems: [String] = []
        var name = regionName
        while true {
            stems.append(name)
            guard let dot = name.lastIndex(of: "."), name[name.index(after: dot)...].allSatisfy(\.isNumber),
                  name.index(after: dot) < name.endIndex else { break }
            name = String(name[..<dot])
        }
        return stems
    }

    // MARK: - Positions

    static func seconds(bar: Int, beat: Int, division: Int, tick: Int, tempo: Double) -> Double {
        (Double((bar - 1) * 4 + (beat - 1)) + Double(division - 1) / 4 + Double(tick - 1) / 960) * 60 / tempo
    }

    /// "16.2.1.65" for Go To Position, from project seconds (4/4).
    static func position(seconds t: Double, tempo: Double) -> String {
        let beats = t * tempo / 60
        let bar = Int(beats / 4) + 1
        let rem = beats - Double(bar - 1) * 4
        let beat = Int(rem) + 1
        let frac = rem - Double(Int(rem))
        let division = Int(frac * 4) + 1
        let tick = min(240, Int(((frac * 4 - Double(Int(frac * 4))) * 240).rounded()) + 1)
        return "\(bar).\(beat).\(division).\(tick)"
    }

    /// The English region help sentence: "Region starts at 16 bars 3 beats 233 ticks  and ends at …".
    static func parseRegionSpan(help: String, tempo: Double) -> (start: Double, end: Double)? {
        guard let startRange = help.range(of: "starts at "), let endRange = help.range(of: " and ends at ") else { return nil }
        func parse(_ s: Substring) -> Double? {
            var v = ["bar": 1, "beat": 1, "division": 1, "tick": 1]
            let words = s.split(separator: " ")
            var found = false
            for (k, w) in words.enumerated() where k + 1 < words.count {
                guard let number = Int(w) else { continue }
                let unit = words[k + 1].hasSuffix("s") ? String(words[k + 1].dropLast()) : String(words[k + 1])
                if v[unit] != nil { v[unit] = number; found = true }
            }
            guard found else { return nil }
            return seconds(bar: v["bar"]!, beat: v["beat"]!, division: v["division"]!, tick: v["tick"]!, tempo: tempo)
        }
        let startText = help[startRange.upperBound..<endRange.lowerBound]
        let rest = help[endRange.upperBound...]
        let endText = rest.split(separator: ",", maxSplits: 1).first ?? rest
        guard let a = parse(startText), let b = parse(endText) else { return nil }
        return (a, b)
    }
}
