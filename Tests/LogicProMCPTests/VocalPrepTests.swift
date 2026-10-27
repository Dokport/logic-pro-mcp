import Foundation
import MCP
import Testing
@testable import LogicProMCP

private let rate = 48_000.0

/// Deterministic noise, so the synthetic takes are the same on every run.
private struct Noise {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Int64(bitPattern: state >> 11) % 2_000_000) / 1_000_000 - 1
    }
}

/// A take: noise floor everywhere, a sung tone (harmonic) where `tone` says, a band-limited
/// noise burst around 2 kHz (a breath) where `breath` says.
private func take(seconds: Double, tone: [ClosedRange<Double>], breath: [ClosedRange<Double>]) -> [Float] {
    var noise = Noise()
    let n = Int(seconds * rate)
    var out = [Float](repeating: 0, count: n)
    // Biquad band-pass at 2 kHz, Q 1.
    let w0 = 2 * Double.pi * 2000 / rate, alpha = sin(w0) / 2
    let b0 = alpha, b2 = -alpha, a0 = 1 + alpha, a1 = -2 * cos(w0), a2 = 1 - alpha
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    for i in 0..<n {
        let t = Double(i) / rate
        var v = Double(noise.next()) * 0.0005                       // ≈ -66 dB floor
        if tone.contains(where: { $0.contains(t) }) {
            v += 0.08 * (sin(2 * .pi * 220 * t) + 0.5 * sin(2 * .pi * 440 * t) + 0.25 * sin(2 * .pi * 660 * t))
        }
        let white = Double(noise.next())
        let band = (b0 * white + b2 * x2 - a1 * y1 - a2 * y2) / a0
        x2 = x1; x1 = white; y2 = y1; y1 = band
        if breath.contains(where: { $0.contains(t) }) { v += band * 0.03 }
        out[i] = Float(v)
    }
    return out
}

@Test("a breath between two phrases is found and kept; a long silence is removed")
func vocalPrepAnalysisFindsBreathAndSilence() throws {
    let x = take(seconds: 7, tone: [0.5...2.0, 2.8...4.3], breath: [2.3...2.75])
    let frames = try #require(VocalPrep.frames(samples: x, sampleRate: rate))
    let a = VocalPrep.analyse(frames)
    let confident = a.breaths.filter(\.confident)
    #expect(confident.count == 1)
    let breath = try #require(confident.first)
    #expect(abs(breath.start - 2.3) < 0.12)
    #expect(abs(breath.end - 2.75) < 0.08)
    // One sound span from the first phrase through the second (the 0.3 s gaps stay), ending
    // shortly after the last phrase: the 2.7 s of silence after it is removed.
    #expect(a.keep.count == 1)
    let keep = try #require(a.keep.first)
    #expect(abs(keep.lowerBound - 0.44) < 0.05)
    #expect(keep.upperBound > 4.3 && keep.upperBound < 4.7)
}

@Test("a silence of at least min_silence splits the sound; a shorter one does not")
func vocalPrepAnalysisSplitsAtLongSilence() throws {
    let x = take(seconds: 8, tone: [0.5...2.0, 3.5...5.0], breath: [])
    let frames = try #require(VocalPrep.frames(samples: x, sampleRate: rate))
    #expect(VocalPrep.analyse(frames, minSilence: 1.0).keep.count == 2)
    #expect(VocalPrep.analyse(frames, minSilence: 2.0).keep.count == 1)
}

private func analysis(keep: [ClosedRange<Double>], breaths: [VocalPrep.Breath], seconds: Double = 20) -> VocalPrep.Analysis {
    // A flat floor: no decay to follow past the regions.
    VocalPrep.Analysis(keep: keep, breaths: breaths, smoothed: Array(repeating: -66, count: Int(seconds * 100)), floor: -66)
}

@Test("the plan splits sound around breaths, pulls in a breath right before a take, and hashes stably")
func vocalPrepPlanPieces() throws {
    let a = analysis(keep: [0.5...6.0], breaths: [
        VocalPrep.Breath(start: 0.6, end: 0.95, peakDB: -50, confident: true),   // right before the edit at 1.0
        VocalPrep.Breath(start: 3.0, end: 3.5, peakDB: -48, confident: true),
        VocalPrep.Breath(start: 4.5, end: 4.7, peakDB: -45, confident: false),
    ])
    let regions = [
        VocalPrep.Region(name: "Voc #01", start: 11.0, end: 13.0, file: "Voc #01.wav", offset: 10),
        VocalPrep.Region(name: "Voc #01.2", start: 13.0, end: 15.0, file: "Voc #01.wav", offset: 10),
    ]
    let plan = try #require(VocalPrep.plan(regions: regions, analyses: ["Voc #01.wav": a]))
    #expect(plan.groups.count == 1)
    #expect(abs(plan.groups[0].newStart - 10.6) < 1e-9)
    let shape = plan.pieces.map { "\($0.kind.rawValue) \(VocalPrep.round4($0.start))-\(VocalPrep.round4($0.end))" }
    #expect(shape == ["breath 10.6-10.95", "sound 10.95-13.0", "breath 13.0-13.5", "sound 13.5-15.0"])
    #expect(plan.uncertainBreaths.count == 1)
    #expect(plan.hash == VocalPrep.plan(regions: regions, analyses: ["Voc #01.wav": a])!.hash)
}

@Test("regions of different takes are separate groups; one take's split regions are one")
func vocalPrepGroups() {
    let regions = [
        VocalPrep.Region(name: "A", start: 1, end: 2, file: "a.wav", offset: 5),
        VocalPrep.Region(name: "A.2", start: 2.5, end: 3, file: "a.wav", offset: 5.0005),
        VocalPrep.Region(name: "A.3", start: 4, end: 5, file: "a.wav", offset: 7),
        VocalPrep.Region(name: "B", start: 6, end: 7, file: "b.wav", offset: 7),
    ]
    #expect(VocalPrep.groups(regions).map { $0.map(\.name) } == [["A", "A.2"], ["A.3"], ["B"]])
}

@Test("a region's file offset is read 70 bytes before its name, only for a name found once")
func vocalPrepRegionOffset() {
    func record(_ name: String, _ offset: UInt32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0xAA, count: 70)
        withUnsafeBytes(of: offset.littleEndian) { bytes.replaceSubrange(0..<4, with: $0) }
        return bytes + Array(name.utf8) + [0, 0]
    }
    let data = Data(record("Voc #07", 529_920) + record("Voc #07.1", 2_050_080) + Array("Voc #07.wav".utf8) + [0])
    #expect(VocalPrep.regionFileOffset(name: "Voc #07", projectData: data) == .found(529_920))
    #expect(VocalPrep.regionFileOffset(name: "Voc #07.1", projectData: data) == .found(2_050_080))
    #expect(VocalPrep.regionFileOffset(name: "Voc #09", projectData: data) == .absent)
    let twice = Data(record("Kick", 1) + record("Kick", 2))
    #expect(VocalPrep.regionFileOffset(name: "Kick", projectData: twice) == .ambiguous(2))
}

@Test("file stems drop the split suffixes Logic appends to a region name")
func vocalPrepFileStems() {
    #expect(VocalPrep.fileStemCandidates(regionName: "Voc #07.1.03") == ["Voc #07.1.03", "Voc #07.1", "Voc #07"])
    #expect(VocalPrep.fileStemCandidates(regionName: "Voc #07") == ["Voc #07"])
    #expect(VocalPrep.fileStemCandidates(regionName: "2 voc kvæd #06.2") == ["2 voc kvæd #06.2", "2 voc kvæd #06"])
}

@Test("region help positions read to the tick and round-trip through Go To Position")
func vocalPrepPositions() throws {
    let help = "Region starts at 16 bars 3 beats 233 ticks  and ends at 17 bars 2 beats 3 divisions 168 ticks , Audio region. An editable object."
    let span = try #require(VocalPrep.parseRegionSpan(help: help, tempo: 70))
    #expect(abs(span.start - VocalPrep.seconds(bar: 16, beat: 3, division: 1, tick: 233, tempo: 70)) < 1e-9)
    #expect(abs(span.end - VocalPrep.seconds(bar: 17, beat: 2, division: 3, tick: 168, tempo: 70)) < 1e-9)
    #expect(VocalPrep.position(seconds: span.start, tempo: 70) == "16.3.1.233")
    #expect(VocalPrep.position(seconds: span.end, tempo: 70) == "17.2.3.168")
    #expect(VocalPrep.parseRegionSpan(help: "Audio region.", tempo: 70) == nil)
}

@Test("prepare_vocal refuses each wrong parameter for itself, before Logic is read")
func vocalPrepValidation() {
    func refused(_ params: [String: Value]) -> Bool { VocalPrepSaga.validate(params) != nil }
    #expect(!refused(["name": .string("Voc")]))
    #expect(!refused(["name": .string("Voc"), "mode": .string("status"), "breath_color": .string("light blue"), "min_silence": .double(1.5)]))
    #expect(refused([:]))
    #expect(refused(["name": .string("")]))
    #expect(refused(["index": .int(3)]))
    #expect(refused(["name": .string("Voc"), "mode": .string("apply")]))
    #expect(refused(["name": .string("Voc"), "breath_color": .string("plaid")]))
    #expect(refused(["name": .string("Voc"), "min_silence": .double(0.1)]))
    #expect(refused(["name": .string("Voc"), "crossfade_ms": .string("lots")]))
    #expect(refused(["name": .string("Voc"), "idempotency_key": .string("")]))
}
