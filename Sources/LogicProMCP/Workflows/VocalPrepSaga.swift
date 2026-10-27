import AVFoundation
import CryptoKit
import Foundation
import MCP

/// `logic_tracks.prepare_vocal`: preflight -> execute -> status for one vocal track.
///
/// Silences of at least `min_silence` seconds are removed, every breath becomes a region of its
/// own in `breath_color`, the remaining sound and each breath are one region apiece, regions
/// that touch get a crossfade and every other edge a short fade. Where a region was edited off in
/// the middle of a decay the decay is kept (up to 0.6 s), and a breath right in front of a
/// region's start is pulled in.
///
/// Preflight reads the track's regions, the saved project file (for where each region sits in
/// its audio file) and the audio files, and returns the plan and its hash without changing
/// anything. The project must be saved: the file offsets come from `ProjectData`. Execute
/// re-plans, requires that hash, and works through the steps within `executeBudgetSeconds`;
/// calling execute again with the same `idempotency_key` continues. Every cut, delete, join and
/// fade is read back; region colours have no AX readback (Undo-title witness), so a complete run
/// answers State B with every other check listed as verified.
enum VocalPrepSaga {
    static let executeBudgetSeconds: Double = 150
    static let modes: Set<String> = ["preflight", "execute", "status"]
    static let audioExtensions = ["wav", "aif", "aiff", "caf"]

    struct Settings: Sendable, Equatable, Codable {
        var minSilence = 1.0
        var crossfadeMs = 10.0
        var fadeOutMs = 30.0
        var fadeInMs = 10.0
        var breathColor = "cyan"
    }

    enum Step: String, CaseIterable, Sendable, Codable {
        case fill, extendStarts = "extend_starts", extendEnd = "extend_end", cut, delete, join
        case trackColor = "track_color", breathColor = "breath_color", fades, verify
    }

    struct Record: Sendable, Codable {
        enum Status: String, Sendable, Codable { case inProgress = "in_progress", completed, failed }
        let key: String
        let index: Int
        let trackName: String
        let tempo: Double
        let plan: VocalPrep.Plan
        let settings: Settings
        let mediaPath: String
        let mediaFiles: Int
        var next = 0
        var status: Status = .inProgress
        var failure: String?
        var log: [String] = []
        var coloredBreaths: Set<Double> = []
        var fadeMismatches: [String] = []
        var verification: Verification?
    }

    struct Verification: Sendable, Codable {
        var regions: Int
        var piecesPlanned: Int
        var piecesUnmatched: [String]
        var regionsUnplanned: [String]
        var clean: Bool { piecesUnmatched.isEmpty && regionsUnplanned.isEmpty }
    }

    /// Kept in memory and on disk, so a run survives a server restart: execute with the same key
    /// continues the plan it was confirmed with, never a plan made from a half-applied track.
    actor Journal {
        static let shared = Journal()
        private var records: [String: Record] = [:]
        static var directory: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LogicProMCP/prepare-vocal", isDirectory: true)
        }
        private static func file(_ key: String) -> URL {
            let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            return directory.appendingPathComponent("\(name).json")
        }
        func record(_ key: String) -> Record? {
            if let cached = records[key] { return cached }
            guard let data = try? Data(contentsOf: Self.file(key)),
                  let loaded = try? JSONDecoder().decode(Record.self, from: data), loaded.key == key else { return nil }
            records[key] = loaded
            return loaded
        }
        func store(_ record: Record) {
            records[record.key] = record
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(record) { try? data.write(to: Self.file(record.key), options: .atomic) }
        }
        func all() -> [Record] { records.values.sorted { $0.key < $1.key } }
    }

    // MARK: - Entry

    static func refuse(_ error: HonestContract.FailureError, _ hint: String, extras: [String: Any] = [:]) -> CallTool.Result {
        var details = extras
        details["hint"] = hint
        details["operation"] = "track.prepare_vocal"
        if details["write_attempted"] == nil { details["write_attempted"] = false }
        return toolTextResult(HonestContract.encodeV2StateC(error: error, extras: details), isError: true)
    }

    enum Parsed<T> { case ok(T), bad(String) }

    static func settings(_ params: [String: Value]) -> Parsed<Settings> {
        var s = Settings()
        func number(_ key: String, _ range: ClosedRange<Double>) -> Parsed<Double?> {
            guard let raw = params[key] else { return .ok(nil) }
            guard let v = raw.doubleValue ?? raw.intValue.map(Double.init) ?? raw.stringValue.flatMap(Double.init),
                  range.contains(v) else { return .bad("'\(key)' must be a number in \(range.lowerBound)...\(range.upperBound)") }
            return .ok(v)
        }
        for (key, range, path) in [("min_silence", 0.3...10.0, \Settings.minSilence), ("crossfade_ms", 1.0...200.0, \Settings.crossfadeMs),
                                   ("fade_out_ms", 0.0...500.0, \Settings.fadeOutMs), ("fade_in_ms", 0.0...500.0, \Settings.fadeInMs)] {
            switch number(key, range) {
            case .bad(let why): return .bad(why)
            case .ok(let v): if let v { s[keyPath: path] = v }
            }
        }
        if let raw = params["breath_color"] {
            guard let name = raw.stringValue, case .resolved = TrackColorPalette.resolve(name: name) else {
                return .bad("'breath_color' must be a palette colour name such as cyan or light blue")
            }
            s.breathColor = name
        }
        return .ok(s)
    }

    static func validate(_ params: [String: Value]) -> CallTool.Result? {
        if let raw = params["mode"], !(raw.stringValue.map(modes.contains) ?? false) {
            return refuse(.invalidParams, "prepare_vocal 'mode' must be preflight, execute or status")
        }
        guard let name = params["name"]?.stringValue, !name.isEmpty else {
            return refuse(.invalidParams, "prepare_vocal requires the track 'name' (matched exactly to one track)")
        }
        for key in ["idempotency_key", "confirmed_plan_hash"] {
            if let raw = params[key], raw.stringValue?.isEmpty != false {
                return refuse(.invalidParams, "'\(key)' must be a non-empty string")
            }
        }
        if case .bad(let why) = settings(params) { return refuse(.invalidParams, why) }
        return nil
    }

    static func handle(params: [String: Value]) async -> CallTool.Result {
        if let invalid = validate(params) { return invalid }
        switch params["mode"]?.stringValue ?? "preflight" {
        case "status": return await status(params)
        case "execute": return await execute(params)
        default: return await preflight(params)
        }
    }

    static func status(_ params: [String: Value]) async -> CallTool.Result {
        guard let key = params["idempotency_key"]?.stringValue else {
            let all = await Journal.shared.all().map { ["idempotency_key": $0.key, "status": $0.status.rawValue, "track": $0.trackName,
                                                        "step": $0.next < Step.allCases.count ? Step.allCases[$0.next].rawValue : "done"] as [String: Any] }
            return toolTextResult(HonestContract.encodeStateA(extras: ["mode": "status", "runs": all]))
        }
        guard let record = await Journal.shared.record(key) else {
            return refuse(.elementNotFound, "No prepare_vocal ran under that key in this server session.")
        }
        return reply(record)
    }

    // MARK: - Observation and plan

    struct Observation: Sendable {
        let index: Int
        let trackName: String
        let tempo: Double
        let regions: [VocalPrep.Region]
        let plan: VocalPrep.Plan
        let mediaDirectory: URL
    }

    private static func appleScriptText(_ source: String) async -> String? {
        AppleScriptChannel.appleScriptResultText(from: await AppleScriptChannel.executeAppleScript(source))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum ObserveOutcome { case observed(Observation), refused(CallTool.Result) }

    static func observe(_ params: [String: Value], settings: Settings) async -> ObserveOutcome {
        let wanted = params["name"]?.stringValue ?? ""
        guard let path = await AppleScriptChannel.currentDocumentPath(), !path.isEmpty,
              let projectDataURL = TrackColorProjectFile.projectDataURL(bundlePath: path) else {
            return .refused(refuse(.elementNotFound, "No saved Logic project is open; nothing was read."))
        }
        let target = LogicProTarget.appleScriptTarget().tellApplicationByBundleID
        let modified = await appleScriptText("\(target)\nreturn modified of front document\nend tell")
        guard modified == "false" else {
            return .refused(refuse(.unsupportedState,
                "The project has unsaved changes. Save it first: where each region sits in its audio file is read from the saved project file.",
                extras: ["modified": modified ?? "unreadable"]))
        }
        guard let tempoData = decodedJSONObject(AccessibilityChannel.defaultGetObservedTempo().message),
              let tempo = tempoData["tempo"] as? Double, tempo > 0 else {
            return .refused(refuse(.readbackUnavailable, "The project tempo did not read; nothing was planned."))
        }
        let index: Int
        switch trackIndex(named: wanted) {
        case .some(.some(let found)): index = found
        case .some(.none): return .refused(refuse(.targetIdentityMismatch, "More than one track is named '\(wanted)'; rename one first."))
        case .none: return .refused(refuse(.elementNotFound, "No track is named '\(wanted)'."))
        }
        let name = wanted
        guard let items = AccessibilityChannel.vocalTrackRegions(index: index, tempo: tempo), !items.isEmpty else {
            return .refused(refuse(.readbackUnavailable, "Track '\(name)' regions did not read (or it has none); nothing was planned."))
        }
        guard let projectData = try? Data(contentsOf: projectDataURL, options: .mappedIfSafe) else {
            return .refused(refuse(.readbackUnavailable, "The saved project file did not read; nothing was planned."))
        }
        let media = URL(fileURLWithPath: path).appendingPathComponent("Media/Audio Files", isDirectory: true)
        var regions: [VocalPrep.Region] = []
        var rates: [String: Double] = [:]
        for item in items {
            guard case .found(let samples) = VocalPrep.regionFileOffset(name: item.name, projectData: projectData) else {
                return .refused(refuse(.readbackUnavailable,
                    "Region '\(item.name)' was not found exactly once in the saved project file; nothing was planned.",
                    extras: ["region": item.name]))
            }
            let candidates = VocalPrep.fileStemCandidates(regionName: item.name).flatMap { stem in
                audioExtensions.map { "\(stem).\($0)" }
            }
            guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: media.appendingPathComponent($0).path) }) else {
                return .refused(refuse(.elementNotFound,
                    "No audio file in the project's Media folder matches region '\(item.name)'; nothing was planned.",
                    extras: ["region": item.name]))
            }
            if rates[file] == nil {
                rates[file] = (try? AVAudioFile(forReading: media.appendingPathComponent(file)))?.processingFormat.sampleRate
            }
            guard let rate = rates[file], rate > 0 else {
                return .refused(refuse(.readbackUnavailable, "Audio file '\(file)' did not open; nothing was planned."))
            }
            regions.append(VocalPrep.Region(name: item.name, start: item.start, end: item.end, file: file,
                                            offset: item.start - Double(samples) / rate))
        }
        var analyses: [String: VocalPrep.Analysis] = [:]
        for file in Set(regions.map(\.file)) {
            guard let audio = VocalPrep.readMono(media.appendingPathComponent(file)),
                  let frames = VocalPrep.frames(samples: audio.samples, sampleRate: audio.sampleRate) else {
                return .refused(refuse(.readbackUnavailable, "Audio file '\(file)' did not read; nothing was planned."))
            }
            analyses[file] = VocalPrep.analyse(frames, minSilence: settings.minSilence)
        }
        guard let plan = VocalPrep.plan(regions: regions, analyses: analyses) else {
            return .refused(refuse(.readbackUnavailable, "The plan could not be built; nothing was changed."))
        }
        return .observed(Observation(index: index, trackName: name, tempo: tempo, regions: regions, plan: plan, mediaDirectory: media))
    }

    /// The one track with exactly this name: nil when none, .some(nil) when several.
    static func trackIndex(named name: String) -> Int?? {
        let headers = AXLogicProElements.allTrackHeaders()
        let hits = headers.indices.filter { AXValueExtractors.extractTrackState(from: headers[$0], index: $0).name == name }
        if hits.isEmpty { return nil }
        return hits.count == 1 ? .some(hits[0]) : .some(nil)
    }

    static func summary(_ o: Observation, settings: Settings) -> [String: Any] {
        func pos(_ t: Double) -> String { VocalPrep.position(seconds: t, tempo: o.tempo) }
        let breaths = o.plan.pieces.filter { $0.kind == .breath }
        return [
            "track": o.trackName, "index": o.index, "tempo": o.tempo,
            "regions_now": o.regions.count, "regions_planned": o.plan.pieces.count,
            "breaths": breaths.map { pos($0.start) },
            "uncertain_breaths": o.plan.uncertainBreaths.map { pos($0.lowerBound) },
            "takes": o.plan.groups.map { g -> [String: Any] in
                ["file": g.file, "from": pos(g.newStart), "to": pos(g.newEnd),
                 "start_moved_earlier": g.newStart < g.oldStart - 0.005, "end_moved_later": g.newEnd > g.oldEnd + 0.005]
            },
            "cuts": o.plan.cuts.count,
            "settings": ["min_silence": settings.minSilence, "crossfade_ms": settings.crossfadeMs,
                         "fade_out_ms": settings.fadeOutMs, "fade_in_ms": settings.fadeInMs, "breath_color": settings.breathColor],
            "plan_hash": o.plan.hash,
        ]
    }

    static func preflight(_ params: [String: Value]) async -> CallTool.Result {
        guard case .ok(let settings) = settings(params) else { return refuse(.invalidParams, "invalid settings") }
        switch await observe(params, settings: settings) {
        case .refused(let refusal): return refusal
        case .observed(let o):
            var extras = summary(o, settings: settings)
            extras["mode"] = "preflight"
            extras["write_attempted"] = false
            return toolTextResult(HonestContract.encodeStateA(extras: extras))
        }
    }

    // MARK: - Execute

    static func execute(_ params: [String: Value]) async -> CallTool.Result {
        guard let key = params["idempotency_key"]?.stringValue else {
            return refuse(.invalidParams, "execute requires an 'idempotency_key' (reuse it to continue a run)")
        }
        if var record = await Journal.shared.record(key) {
            if record.status == .completed { return reply(record) }
            // A failed step is tried again from where it stopped (after the cause is fixed).
            record.status = .inProgress
            record.failure = nil
            await run(&record)
            return reply(record)
        }
        guard let confirmed = params["confirmed_plan_hash"]?.stringValue else {
            return refuse(.invalidParams, "execute requires 'confirmed_plan_hash' from preflight")
        }
        guard case .ok(let settings) = settings(params),
              case .resolved(let swatch) = TrackColorPalette.resolve(name: settings.breathColor) else {
            return refuse(.invalidParams, "invalid settings")
        }
        switch await observe(params, settings: settings) {
        case .refused(let refusal): return refusal
        case .observed(let o):
            guard o.plan.hash == confirmed else {
                return refuse(.unsupportedState, "The plan changed since preflight; run preflight again.",
                              extras: ["plan_hash": o.plan.hash])
            }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: o.mediaDirectory.path).count) ?? -1
            _ = swatch
            var record = Record(key: key, index: o.index, trackName: o.trackName, tempo: o.tempo, plan: o.plan,
                                settings: settings, mediaPath: o.mediaDirectory.path, mediaFiles: files)
            await Journal.shared.store(record)
            await run(&record)
            return reply(record)
        }
    }

    enum StepOutcome { case done, incomplete, failed(String) }

    private static func run(_ record: inout Record) async {
        let began = Date()
        guard case .some(.some(let index)) = trackIndex(named: record.trackName), index == record.index else {
            record.status = .failed
            record.failure = "track '\(record.trackName)' is no longer the one track at index \(record.index)"
            await Journal.shared.store(record)
            return
        }
        let front = FrontmostGate.prepareObserved(observe: AXLogicProElements.Runtime.production.observeFrontmost,
                                                  activate: { ProcessUtils.activateLogicPro() }, sleepMicros: { usleep($0) })
        guard front.preparation.isReady else {
            record.log.append("Logic Pro could not be brought to the front; nothing was done this call.")
            await Journal.shared.store(record)
            return
        }
        let deadline = began.addingTimeInterval(executeBudgetSeconds)
        while record.next < Step.allCases.count {
            let step = Step.allCases[record.next]
            switch perform(step, &record, deadline: deadline) {
            case .done:
                record.log.append("\(step.rawValue): done")
                record.next += 1
            case .incomplete:
                await Journal.shared.store(record)
                return
            case .failed(let why):
                record.status = .failed
                record.failure = "\(step.rawValue): \(why)"
                await Journal.shared.store(record)
                return
            }
            await Journal.shared.store(record)
        }
        record.status = .completed
        await Journal.shared.store(record)
    }

    // MARK: - Steps

    private static func perform(_ step: Step, _ r: inout Record, deadline: Date) -> StepOutcome {
        let index = r.index, tempo = r.tempo, plan = r.plan
        func regions() -> [AccessibilityChannel.VocalRegionItem]? { AccessibilityChannel.vocalTrackRegions(index: index, tempo: tempo) }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.003 }
        func split(at t: Double) -> Bool {
            guard AccessibilityChannel.vocalGoTo(VocalPrep.position(seconds: t, tempo: tempo)),
                  AccessibilityChannel.vocalSelectTrack(index: index, tempo: tempo),
                  AccessibilityChannel.vocalPressMenu(["Edit", "Split", "Regions at Playhead"]) else { return false }
            usleep(400_000)
            return regions()?.contains { near($0.start, t) } == true
        }
        func delete(_ name: String) -> Bool {
            guard AccessibilityChannel.vocalSelectExactly([name], index: index, tempo: tempo) != nil,
                  AccessibilityChannel.vocalPressMenu(["Edit", "Delete"]) else { return false }
            usleep(400_000)
            return regions()?.contains { $0.name == name } == false
        }
        func overBudget() -> Bool { Date() > deadline }

        switch step {
        case .fill:
            guard AccessibilityChannel.vocalSelectTrack(index: index, tempo: tempo) else { return .failed("the track's regions could not be selected") }
            guard AccessibilityChannel.vocalPressMenu(["Edit", "Trim", "Region End to Next Region"]) else {
                return .failed("Edit > Trim > Region End to Next Region was not available")
            }
            usleep(800_000)
            guard let rs = regions() else { return .failed("regions unreadable after filling") }
            // A region that already reaches the end of its audio file cannot fill further; that gap
            // only matters where the plan needs sound.
            let gaps = zip(rs, rs.dropFirst()).filter { !near($0.end, $1.start) }.map { ($0.end, $1.start) }
            let needed = gaps.filter { gap in plan.pieces.contains { $0.start < gap.1 - 0.003 && gap.0 + 0.003 < $0.end } }
            if !gaps.isEmpty { r.log.append("fill: \(gaps.count) gap(s) left where a region reached its file's end") }
            return needed.isEmpty ? .done : .failed("\(needed.count) gap(s) remained where the plan needs sound")

        case .extendStarts:
            for g in plan.groups where g.newStart < g.oldStart - 0.005 {
                if overBudget() { return .incomplete }
                guard let rs = regions() else { return .failed("regions unreadable") }
                if rs.contains(where: { $0.start <= g.newStart + 0.003 && $0.end > g.newStart + 0.003 && near($0.start, g.newStart) }) { continue }
                guard let first = rs.first(where: { near($0.start, g.oldStart) }) else {
                    // Already reaching further back (a hand edit): the cuts take it from here.
                    if rs.contains(where: { $0.start < g.newStart && $0.end > g.oldStart - 0.003 }) { continue }
                    return .failed("no region starts at the take's start \(VocalPrep.position(seconds: g.oldStart, tempo: tempo))")
                }
                if let previous = rs.last(where: { $0.end <= g.oldStart + 0.003 && $0.start < g.oldStart - 0.003 }), previous.end > g.newStart {
                    // The previous take's region (filled up to here) gives way, then the start moves back.
                    guard split(at: g.newStart) else { return .failed("split at \(VocalPrep.position(seconds: g.newStart, tempo: tempo)) not read back") }
                    guard let piece = regions()?.first(where: { near($0.start, g.newStart) && near($0.end, g.oldStart) }),
                          delete(piece.name) else { return .failed("the gap before the take could not be cleared") }
                }
                guard AccessibilityChannel.vocalSelectExactly([first.name], index: index, tempo: tempo) != nil else {
                    return .failed("the take's first region could not be selected alone")
                }
                if rs.contains(where: { $0.end <= g.oldStart + 0.003 && $0.start < g.oldStart - 0.003 }) {
                    guard AccessibilityChannel.vocalPressMenu(["Edit", "Trim", "Region Start to Previous Region"]) else {
                        return .failed("Edit > Trim > Region Start to Previous Region was not available")
                    }
                } else {
                    // The track's first region: drag its lower-left corner past the breath.
                    guard let frame = first.frame, first.end > first.start else { return .failed("first region has no frame") }
                    let pointsPerSecond = frame.width / CGFloat(first.end - first.start)
                    let dx = -max(8, CGFloat(g.oldStart - g.newStart + 0.3) * pointsPerSecond)
                    guard AccessibilityChannel.vocalDragCorner(first, left: true, dx: dx) else {
                        return .failed("the track's first region must be on screen (scroll the Tracks area to it) to pull its start back; call execute again")
                    }
                }
                usleep(500_000)
                guard let moved = regions()?.first(where: { $0.name == first.name }), moved.start <= g.newStart + 0.003 else {
                    return .failed("the start of \(first.name) did not move back to \(VocalPrep.position(seconds: g.newStart, tempo: tempo))")
                }
            }
            return .done

        case .extendEnd:
            guard let last = plan.groups.last, last.newEnd > last.oldEnd + 0.005, let rs = regions(), let tail = rs.last else { return .done }
            if tail.end >= last.newEnd - 0.003 { return .done }
            guard let frame = tail.frame, tail.end > tail.start else { return .failed("last region has no frame") }
            let pointsPerSecond = frame.width / CGFloat(tail.end - tail.start)
            let dx = max(8, CGFloat(last.newEnd - tail.end + 0.3) * pointsPerSecond)
            guard AccessibilityChannel.vocalDragCorner(tail, left: false, dx: dx) else {
                return .failed("the track's last region must be on screen (scroll the Tracks area to it) to keep its decay; call execute again")
            }
            usleep(500_000)
            guard let moved = regions()?.first(where: { $0.name == tail.name }), moved.end >= last.newEnd - 0.003 else {
                return .failed("the end of \(tail.name) did not move to \(VocalPrep.position(seconds: last.newEnd, tempo: tempo))")
            }
            return .done

        case .cut:
            for t in plan.cuts {
                if overBudget() { return .incomplete }
                guard let rs = regions() else { return .failed("regions unreadable") }
                if rs.contains(where: { near($0.start, t) }) || !rs.contains(where: { $0.start < t && $0.end > t + 0.003 }) { continue }
                guard split(at: t) else { return .failed("split at \(VocalPrep.position(seconds: t, tempo: tempo)) not read back") }
            }
            return .done

        case .delete:
            while true {
                if overBudget() { return .incomplete }
                guard let rs = regions() else { return .failed("regions unreadable") }
                let outside = rs.filter { reg in !plan.pieces.contains { $0.start < reg.end - 0.003 && reg.start + 0.003 < $0.end } }
                let straddling = rs.filter { reg in
                    plan.pieces.contains { $0.start < reg.end - 0.003 && reg.start + 0.003 < $0.end }
                        && !plan.pieces.contains { $0.start - 0.003 <= reg.start && reg.end <= $0.end + 0.003 }
                }
                if !straddling.isEmpty { return .failed("region \(straddling[0].name) lies across a planned edge") }
                guard let victim = outside.first else { return .done }
                guard delete(victim.name) else { return .failed("\(victim.name) could not be deleted") }
            }

        case .join:
            while true {
                if overBudget() { return .incomplete }
                guard let rs = regions() else { return .failed("regions unreadable") }
                let run = plan.pieces.lazy.map { p in rs.filter { p.start - 0.003 <= $0.start && $0.end <= p.end + 0.003 } }
                    .first { $0.count > 1 }
                guard let run else { return .done }
                let names = Set(run.map(\.name))
                // Join is validated against the Tracks area's key focus: a header click gives it.
                _ = AccessibilityChannel.vocalSelectTrack(index: index, tempo: tempo)
                guard AccessibilityChannel.vocalSelectExactly(names, index: index, tempo: tempo) != nil else {
                    return .failed("regions \(names.sorted()) could not be selected together")
                }
                guard AccessibilityChannel.vocalPressMenu(["Edit", "Bounce or Join", "Join"]) else {
                    return .failed("Edit > Bounce or Join > Join was not available for \(names.sorted())")
                }
                usleep(800_000)
                if AXLogicProElements.dialogPresent() {
                    AXMouseHelper.pressEscape()
                    return .failed("Join asked a question (it would have written a new audio file); cancelled")
                }
                let files = (try? FileManager.default.contentsOfDirectory(atPath: r.mediaPath).count) ?? -1
                guard files == r.mediaFiles else { return .failed("Join changed the number of audio files (\(r.mediaFiles) -> \(files))") }
                guard let after = regions(), after.contains(where: { near($0.start, run.first!.start) && near($0.end, run.last!.end) }) else {
                    return .failed("the joined region over \(names.sorted()) did not read back")
                }
            }

        case .trackColor:
            switch AccessibilityChannel.vocalColorTrackRegionsByTrack(index: index, tempo: tempo) {
            case .failure(let error): return .failed("Color Regions/Cells by Track Color: \(error.reason)")
            case .success(let title):
                if title.isEmpty {
                    r.log.append("track_color: the regions already had the track's colour (no Undo step)")
                    return .done
                }
                guard AXLocalePolicy.colorRegionsUndoOperation.containsAny(in: title) else {
                    return .failed("Color Regions/Cells by Track Color did not answer with its Undo title (\(title))")
                }
                return .done
            }

        case .breathColor:
            for p in plan.pieces where p.kind == .breath && !r.coloredBreaths.contains(VocalPrep.round4(p.start)) {
                if overBudget() { return .incomplete }
                guard let rs = regions(), let reg = rs.first(where: { near($0.start, p.start) && near($0.end, p.end) }),
                      AccessibilityChannel.vocalSelectExactly([reg.name], index: index, tempo: tempo) != nil else {
                    return .failed("the breath at \(VocalPrep.position(seconds: p.start, tempo: tempo)) is not one region")
                }
                guard case .resolved(let swatch) = TrackColorPalette.resolve(name: r.settings.breathColor),
                      let title = AccessibilityChannel.vocalColorSelectedRegion(reg, swatch: swatch),
                      title.localizedCaseInsensitiveContains("Region Color") else {
                    return .failed("the breath at \(VocalPrep.position(seconds: p.start, tempo: tempo)) did not answer Change Region Color")
                }
                r.coloredBreaths.insert(VocalPrep.round4(p.start))
            }
            return .done

        case .fades:
            guard let rs = regions() else { return .failed("regions unreadable") }
            for (i, reg) in rs.enumerated() {
                if overBudget() { return .incomplete }
                let gapBefore = i == 0 || !near(rs[i - 1].end, reg.start)
                let touchesNext = i + 1 < rs.count && near(rs[i + 1].start, reg.end)
                let want = AccessibilityChannel.VocalFades(fadeIn: gapBefore ? r.settings.fadeInMs : 0,
                                                           fadeOut: touchesNext ? r.settings.crossfadeMs : r.settings.fadeOutMs,
                                                           type: touchesNext ? "X" : "Out")
                guard AccessibilityChannel.vocalSelectExactly([reg.name], index: index, tempo: tempo) != nil else {
                    return .failed("\(reg.name) could not be selected alone")
                }
                usleep(100_000)
                if AccessibilityChannel.vocalReadFades() != want {
                    AccessibilityChannel.vocalWriteFades(want)
                    usleep(100_000)
                }
                let got = AccessibilityChannel.vocalReadFades()
                r.fadeMismatches.removeAll { $0.hasPrefix(reg.name + ":") }
                if got != want { r.fadeMismatches.append("\(reg.name): \(String(describing: got))") }
            }
            return .done

        case .verify:
            guard let rs = regions() else { return .failed("regions unreadable") }
            let unmatched = plan.pieces.filter { p in rs.filter { near($0.start, p.start) && near($0.end, p.end) }.count != 1 }
            let extra = rs.filter { reg in !plan.pieces.contains { near($0.start, reg.start) && near($0.end, reg.end) } }
            r.verification = Verification(regions: rs.count, piecesPlanned: plan.pieces.count,
                                          piecesUnmatched: unmatched.map { VocalPrep.position(seconds: $0.start, tempo: tempo) },
                                          regionsUnplanned: extra.map(\.name))
            return .done
        }
    }

    // MARK: - Reply

    static func reply(_ r: Record) -> CallTool.Result {
        func pos(_ t: Double) -> String { VocalPrep.position(seconds: t, tempo: r.tempo) }
        var extras: [String: Any] = [
            "mode": "execute", "idempotency_key": r.key, "status": r.status.rawValue, "track": r.trackName,
            "steps_done": Array(Step.allCases.prefix(r.next).map(\.rawValue)), "log": r.log,
            "breaths": r.plan.pieces.filter { $0.kind == .breath }.map { pos($0.start) },
            "breaths_colored": r.coloredBreaths.count, "plan_hash": r.plan.hash, "write_attempted": true,
        ]
        if let v = r.verification {
            extras["verification"] = ["regions": v.regions, "pieces_planned": v.piecesPlanned, "pieces_unmatched": v.piecesUnmatched,
                                      "regions_unplanned": v.regionsUnplanned, "fade_mismatches": r.fadeMismatches]
        }
        switch r.status {
        case .failed:
            extras["failure"] = r.failure ?? "unknown"
            return toolTextResult(HonestContract.encodeV2StateC(error: .unsupportedState, extras: extras.merging(
                ["hint": "Stopped at a step that did not read back; earlier steps stay applied (Edit > Undo reverts them one by one)."]) { $1 }),
                isError: true)
        case .inProgress:
            extras["hint"] = "The time budget of one call is spent; call execute again with the same idempotency_key to continue."
            return toolTextResult(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras.merging(["reason_detail": "prepare_vocal_in_progress"]) { $1 }))
        case .completed:
            let clean = r.verification?.clean == true && r.fadeMismatches.isEmpty
            extras["hint"] = clean
                ? "Every cut, delete, join and fade read back as planned; region colours have no AX readback (Undo-title witness)."
                : "Done, but some regions or fades did not read back as planned; see verification."
            return toolTextResult(HonestContract.encodeStateB(reason: clean ? .readbackUnavailable : .readbackMismatch, extras: extras))
        }
    }
}
