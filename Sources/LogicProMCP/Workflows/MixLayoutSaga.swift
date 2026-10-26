import ApplicationServices
import Foundation
import MCP

/// `logic_project.apply_mix_layout`: preflight -> execute -> status for a `MixLayoutSpec`.
///
/// Preflight reads the track list and the Mixer and returns the step plan and its hash; it writes
/// nothing to the project (it may show the Mixer to read it). Execute re-plans, refuses unless the
/// caller confirmed exactly that hash, and runs the steps in order through the same verified
/// operations a caller would use (move_track, set_output_verified, create_send,
/// create_track_for_strip, rename, create_stack, set_color, insert_verified,
/// set_send_level_verified). Each step must come back State A — a colour may come back State B
/// with its Undo-title witness, as set_color does — or the saga stops there and says which step
/// and why. Nothing is compensated: the steps already applied stay, and the record lists them.
///
/// A whole layout takes longer than one tool deadline, so execute works for at most
/// `executeBudgetSeconds` and then answers State B `mix_layout_in_progress`; calling execute again
/// with the same `idempotency_key` continues from the next step. `status` reads the record. The
/// journal lives in this server process only.
enum MixLayoutSaga {
    static let executeBudgetSeconds: Double = 200
    static let modes: Set<String> = ["preflight", "execute", "status"]

    struct Record: Sendable {
        enum Status: String, Sendable { case inProgress = "in_progress", completed, failed }
        let key: String
        let planHash: String
        let steps: [MixLayoutStep]
        let colorReadback: String
        var results: [String] = []
        var next = 0
        var status: Status = .inProgress
        var receivers: [String: String] = [:]
        var receiverTracks: [String: Int] = [:]
        var mixerShown: Bool?
        var failure: String?
    }

    actor Journal {
        static let shared = Journal()
        private var records: [String: Record] = [:]
        func record(_ key: String) -> Record? { records[key] }
        func store(_ record: Record) { records[record.key] = record }
        func all() -> [Record] { records.values.sorted { $0.key < $1.key } }
    }

    // MARK: - Entry

    /// Every refusal carries the full HC v2 shape (`verified:false`).
    static func refuse(_ error: HonestContract.FailureError, _ hint: String, extras: [String: Any] = [:]) -> CallTool.Result {
        var details = extras
        details["hint"] = hint
        if details["write_attempted"] == nil { details["write_attempted"] = false }
        return toolTextResult(HonestContract.encodeV2StateC(error: error, extras: details), isError: true)
    }

    /// Parameter checks that need no Logic: each wrong value is refused for itself.
    static func validate(_ params: [String: Value]) -> CallTool.Result? {
        if let raw = params["mode"] {
            guard let mode = raw.stringValue, modes.contains(mode) else {
                return refuse(.invalidParams, "apply_mix_layout 'mode' must be preflight, execute or status")
            }
        }
        if let raw = params["color_readback"] {
            guard let value = raw.stringValue, ["ax", "project_file"].contains(value) else {
                return refuse(.invalidParams, "'color_readback' must be ax or project_file")
            }
        }
        for key in ["idempotency_key", "confirmed_plan_hash"] {
            if let raw = params[key], raw.stringValue?.isEmpty != false {
                return refuse(.invalidParams, "'\(key)' must be a non-empty string")
            }
        }
        return nil
    }

    /// `status`: the journal only, so it needs no Logic dependencies. Without a key it lists the
    /// layouts this server session has run.
    static func status(_ params: [String: Value]) async -> CallTool.Result {
        guard let key = params["idempotency_key"]?.stringValue, !key.isEmpty else {
            let all = await Journal.shared.all().map { ["idempotency_key": $0.key, "status": $0.status.rawValue,
                                                        "steps_done": $0.next, "step_count": $0.steps.count] as [String: Any] }
            return toolTextResult(HonestContract.encodeStateA(extras: ["mode": "status", "layouts": all]))
        }
        guard let record = await Journal.shared.record(key) else {
            return refuse(.elementNotFound, "No layout ran under that key in this server session.")
        }
        return reply(record, duplicate: false)
    }

    static func handle(params: [String: Value], dependencies: HandlerDependencies) async -> CallTool.Result {
        if let invalid = validate(params) { return invalid }
        switch params["mode"]?.stringValue ?? "preflight" {
        case "status":
            return await status(params)
        case "execute":
            return await execute(params: params, dependencies: dependencies)
        default:
            return await preflight(params: params, dependencies: dependencies)
        }
    }

    // MARK: - Preflight

    private enum Observation {
        case observed(tracks: [String], usedBuses: Set<Int>)
        case refused(CallTool.Result)
    }

    private static func observe(_ dependencies: HandlerDependencies) async -> Observation {
        guard let tracks = liveTrackNames(dependencies) else {
            return .refused(refuse(.readbackUnavailable,  "The track list could not be read completely; nothing was planned.", extras: ["write_attempted": false]))
        }
        // The Mixer is read for the buses in use; it must be shown for that (a view change only).
        guard await ensureMixer(shown: true, dependencies) else {
            return .refused(refuse(.unsupportedState, "The Mixer could not be shown, so the buses in use are unknown; nothing was planned."))
        }
        guard let strips = await mixerStrips(dependencies) else {
            return .refused(refuse(.readbackUnavailable,
                "The Mixer's strips did not read, so the buses in use are unknown; nothing was planned."))
        }
        var titles: [String] = []
        for strip in strips {
            titles += ["input", "output"].compactMap { strip[$0] as? String }
            for slot in strip["send_slots"] as? [[String: Any]] ?? [] {
                titles += ["destination_display", "checked_destination"].compactMap { slot[$0] as? String }
            }
            for send in strip["sends"] as? [[String: Any]] ?? [] {
                if let destination = send["destination"] as? String { titles.append(destination) }
            }
        }
        return .observed(tracks: tracks, usedBuses: MixLayoutPlanner.busNumbers(in: titles))
    }

    private static func preflight(params: [String: Value], dependencies: HandlerDependencies) async -> CallTool.Result {
        let spec: MixLayoutSpec
        switch MixLayoutSpec.parse(params["spec"]) {
        case .success(let parsed): spec = parsed
        case .failure(let failure): return refuse(.invalidParams, failure.message, extras: ["write_attempted": false])
        }
        let tracks: [String], used: Set<Int>
        switch await observe(dependencies) {
        case .refused(let result): return result
        case .observed(let observedTracks, let observedBuses): (tracks, used) = (observedTracks, observedBuses)
        }
        let plan = MixLayoutPlanner.plan(spec: spec, trackNames: tracks, usedBuses: used)
        var extras: [String: Any] = [
            "mode": "preflight",
            "plan_hash": plan.hash,
            "steps": plan.steps.map(\.json),
            "step_count": plan.steps.count,
            "blockers": plan.blockers.map(\.json),
            "case_insensitive_matches": plan.caseInsensitiveMatches,
            "buses": plan.buses,
            "buses_in_use": used.sorted(),
            "tracks": tracks,
            "write_attempted": false,
        ]
        guard plan.blockers.isEmpty else {
            return refuse(.unsupportedState,  "The spec cannot be applied to this project as it stands; see blockers. Nothing was changed.",
                extras: extras)
        }
        extras["next"] = "call execute with this spec, confirmed_plan_hash and an idempotency_key"
        return toolTextResult(HonestContract.encodeStateA(extras: extras))
    }

    // MARK: - Execute

    private static func execute(params: [String: Value], dependencies: HandlerDependencies) async -> CallTool.Result {
        guard let key = params["idempotency_key"]?.stringValue, !key.isEmpty else {
            return refuse(.invalidParams, "execute requires 'idempotency_key'", extras: ["write_attempted": false])
        }
        guard let confirmed = params["confirmed_plan_hash"]?.stringValue, !confirmed.isEmpty else {
            return refuse(.invalidParams, "execute requires 'confirmed_plan_hash' from preflight", extras: ["write_attempted": false])
        }
        if let existing = await Journal.shared.record(key) {
            guard existing.planHash == confirmed else {
                return refuse(.invalidParams,  "This key belongs to a different plan.",
                                        extras: ["write_attempted": false, "plan_hash": existing.planHash])
            }
            guard existing.status == .inProgress else { return reply(existing, duplicate: true) }
            return await run(existing, dependencies)
        }
        let colorReadback = params["color_readback"]?.stringValue ?? "ax"
        guard ["ax", "project_file"].contains(colorReadback) else {
            return refuse(.invalidParams, "'color_readback' must be ax or project_file", extras: ["write_attempted": false])
        }
        let spec: MixLayoutSpec
        switch MixLayoutSpec.parse(params["spec"]) {
        case .success(let parsed): spec = parsed
        case .failure(let failure): return refuse(.invalidParams, failure.message, extras: ["write_attempted": false])
        }
        let tracks: [String], used: Set<Int>
        switch await observe(dependencies) {
        case .refused(let result): return result
        case .observed(let observedTracks, let observedBuses): (tracks, used) = (observedTracks, observedBuses)
        }
        let plan = MixLayoutPlanner.plan(spec: spec, trackNames: tracks, usedBuses: used)
        guard plan.blockers.isEmpty else {
            return refuse(.unsupportedState,  "The spec has blockers against the project now; nothing was changed.",
                                    extras: ["blockers": plan.blockers.map(\.json), "write_attempted": false])
        }
        guard plan.hash == confirmed else {
            return refuse(.staleSnapshot,  "The project no longer gives the plan that was confirmed; run preflight again. Nothing was changed.",
                extras: ["plan_hash": plan.hash, "steps": plan.steps.map(\.json), "write_attempted": false])
        }
        let record = Record(key: key, planHash: plan.hash, steps: plan.steps, colorReadback: colorReadback, mixerShown: nil)
        await Journal.shared.store(record)
        return await run(record, dependencies)
    }

    private static func run(_ start: Record, _ dependencies: HandlerDependencies) async -> CallTool.Result {
        var record = start
        let began = Date()
        while record.next < record.steps.count {
            if Date().timeIntervalSince(began) > executeBudgetSeconds {
                await Journal.shared.store(record)
                return reply(record, duplicate: false)
            }
            let step = record.steps[record.next]
            if let shown = step.mixerShown, record.mixerShown != shown {
                guard await ensureMixer(shown: shown, dependencies) else {
                    record.status = .failed
                    record.failure = "the Mixer could not be \(shown ? "shown" : "hidden") before step \(record.next)"
                    await Journal.shared.store(record)
                    return reply(record, duplicate: false)
                }
                record.mixerShown = shown
            }
            let outcome = await perform(step, &record, dependencies)
            var entry = step.json
            entry["index"] = record.next
            entry["state"] = outcome.state
            entry["detail"] = outcome.detail
            record.results.append(jsonText(entry))
            guard outcome.accepted else {
                record.status = .failed
                record.failure = "step \(record.next) (\(step.json["step"] ?? "")) answered \(outcome.state): \(outcome.detail)"
                await Journal.shared.store(record)
                return reply(record, duplicate: false)
            }
            record.next += 1
            await Journal.shared.store(record)
        }
        if record.colorReadback == "project_file" { await verifyColorsFromProjectFile(&record, dependencies) }
        record.status = .completed
        await Journal.shared.store(record)
        return reply(record, duplicate: false)
    }

    /// `color_readback: project_file`: save the project once and read every coloured track's
    /// record from `ProjectData`. A colour step whose track reads the expected stored index there
    /// becomes State A; anything unreadable or different stays as it was, with the reason added.
    private static func verifyColorsFromProjectFile(_ record: inout Record, _ deps: HandlerDependencies) async {
        let saved = await deps.router.route(operation: "project.save")
        let saveJSON = decodedJSONObject(saved.message) ?? [:]
        let data: Data? = {
            guard saved.isSuccess, saveJSON["verified"] as? Bool == true,
                  let path = saveJSON["document_path"] as? String,
                  let url = TrackColorProjectFile.projectDataURL(bundlePath: path) else { return nil }
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }()
        for (offset, text) in record.results.enumerated() {
            guard var entry = decodedJSONObject(text), entry["step"] as? String == "set_color",
                  entry["state"] as? String != "A",
                  let track = entry["track"] as? String, let color = entry["color"] as? String,
                  case .resolved(let swatch) = TrackColorPalette.resolve(name: color) else { continue }
            var detail = entry["detail"] as? [String: Any] ?? [:]
            guard let data else {
                detail["project_file_readback"] = "project_save_unverified"
                entry["detail"] = detail
                record.results[offset] = jsonText(entry)
                continue
            }
            switch TrackColorProjectFile.colorIndex(trackName: track, projectData: data) {
            case .found(let observed) where observed == swatch.storedIndex:
                entry["state"] = "A"
                detail["verify_source"] = "project_file"
                detail["observed_stored_index"] = observed
            case .found(let observed):
                detail["project_file_readback"] = "mismatch"
                detail["observed_stored_index"] = observed
            case .absent:
                detail["project_file_readback"] = "track_record_not_found"
            case .ambiguous(let count):
                detail["project_file_readback"] = "track_record_ambiguous (\(count))"
            }
            entry["detail"] = detail
            record.results[offset] = jsonText(entry)
        }
    }

    // MARK: - Steps

    private struct Outcome {
        let state: String
        let accepted: Bool
        let detail: [String: Any]
    }

    private static func perform(_ step: MixLayoutStep, _ record: inout Record, _ deps: HandlerDependencies) async -> Outcome {
        func outcome(_ reply: [String: Any], acceptB: Bool = false, keys: [String]) -> Outcome {
            let state = reply["state"] as? String ?? "C"
            var detail: [String: Any] = [:]
            for key in keys + ["error", "reason", "hint"] { if let value = reply[key] { detail[key] = value } }
            return Outcome(state: state, accepted: state == "A" || (acceptB && state == "B"), detail: detail)
        }
        func refused(_ why: String) -> Outcome { Outcome(state: "C", accepted: false, detail: ["reason": why]) }

        switch step {
        case let .moveTrack(name, after):
            let reply = await call("logic_tracks", "move_track", ["name": .string(name), "after": .string(after)], deps)
            return outcome(reply, keys: ["after_order"])

        case let .routeOutput(track, bus, createReceiver, owner):
            guard let index = trackIndex(track, deps) else { return refused("track '\(track)' not found") }
            var params: [String: Value] = [
                "track": .int(index),
                "destination": .object(["kind": .string("bus"), "number": .int(bus)]),
            ]
            if createReceiver { params["create_receiver"] = .bool(true) }
            let reply = await call("logic_mixer", "set_output_verified", params, deps)
            if reply["state"] as? String == "A" {
                if createReceiver {
                    guard let receiver = (reply["created_receiver"] as? [String: Any])?["name"] as? String else {
                        return refused("the output was set but no created receiver was reported")
                    }
                    record.receivers[owner] = receiver
                }
                return outcome(reply, keys: ["after", "created_receiver"])
            }
            // The press happened but the operation's own after-read missed it (measured: a second
            // receiver's strip can read late). An independent read of the whole Mixer decides:
            // the source's output reads the bus and exactly one strip reads it as input.
            guard reply["write_attempted"] as? Bool != false,
                  let strips = await mixerStrips(deps),
                  strips.first(where: { ($0["name"] as? String) == track })?["output"] as? String == "Bus \(bus)" else {
                return outcome(reply, keys: ["after", "created_receiver"])
            }
            let receivers = strips.filter { ($0["input"] as? String) == "Bus \(bus)" }.compactMap { $0["name"] as? String }
            guard receivers.count == 1 else { return outcome(reply, keys: ["after", "created_receiver"]) }
            if createReceiver { record.receivers[owner] = receivers[0] }
            return Outcome(state: "A", accepted: true, detail: [
                "verify_source": "independent_mixer_read", "receiver": receivers[0],
                "operation_reply_state": reply["state"] ?? NSNull(), "operation_reply_reason": reply["reason"] ?? NSNull(),
            ])

        case let .createSend(from, bus, createReceiver, owner):
            var params: [String: Value] = ["strip": .string(from), "bus": .int(bus)]
            if createReceiver { params["create_receiver"] = .bool(true) }
            let reply = await call("logic_mixer", "create_send", params, deps)
            if createReceiver, reply["state"] as? String == "A" {
                guard let receiver = (reply["created_receiver"] as? [String: Any])?["name"] as? String else {
                    return refused("the send was created but no created receiver was reported")
                }
                record.receivers[owner] = receiver
            }
            return outcome(reply, keys: ["send_ordinal", "created_receiver"])

        case let .createTrackForReceiver(owner, after):
            guard let strip = record.receivers[owner] else { return refused("no receiver was created for \(owner)") }
            if let names = liveTrackNames(deps), let anchor = after.flatMap({ names.firstIndex(of: $0) }) ?? names.indices.last {
                _ = await call("logic_tracks", "select", ["index": .int(anchor)], deps)
            }
            let reply = await call("logic_mixer", "create_track_for_strip", ["strip": .string(strip)], deps)
            if reply["state"] as? String == "A", let index = reply["track_index"] as? Int {
                record.receiverTracks[owner] = index
            }
            return outcome(reply, keys: ["track_index"])

        case let .renameReceiverTrack(owner):
            guard let index = record.receiverTracks[owner] else { return refused("no track was created for \(owner)") }
            let reply = await call("logic_tracks", "rename", ["index": .int(index), "name": .string(owner)], deps)
            return outcome(reply, keys: ["observed"])

        case let .placeTrack(name, after):
            guard let names = liveTrackNames(deps), let from = names.firstIndex(of: name),
                  let anchor = names.firstIndex(of: after) else { return refused("'\(name)' or '\(after)' is not in the track list") }
            if from == anchor + 1 { return Outcome(state: "A", accepted: true, detail: ["already_in_place": true]) }
            guard anchor < from else {
                return Outcome(state: "B", accepted: true, detail: [
                    "reason": "cannot_move_down", "hint": "'\(name)' sits above '\(after)' and was left where Logic put it"])
            }
            let reply = await call("logic_tracks", "move_track", ["name": .string(name), "after": .string(after)], deps)
            return outcome(reply, keys: ["after_order"])

        case let .summingStack(name, members):
            let reply = await call("logic_tracks", "create_stack", [
                "members": .array(members.map { .string($0) }), "kind": .string("summing"), "name": .string(name),
            ], deps)
            return outcome(reply, keys: ["stack_index", "after_order"])

        case let .setColor(track, color):
            guard let index = trackIndex(track, deps) else { return refused("track '\(track)' not found") }
            let reply = await call("logic_tracks", "set_color", [
                "index": .int(index), "expected_name": .string(track), "color": .string(color),
                // One save for every colour at the end (`verifyColorsFromProjectFile`), not one per step.
                "readback": .string("ax"),
            ], deps)
            // Logic exposes no AX colour read: State B with the Undo-title witness is set_color's answer.
            let witnessed = reply["undo_witness"] != nil
            return outcome(reply, acceptB: witnessed, keys: ["undo_witness", "readback_source"])

        case let .insertPlugin(track, plugin, slot):
            guard let index = trackIndex(track, deps) else { return refused("track '\(track)' not found") }
            var params: [String: Value] = [
                "track": .int(index), "expected_name": .string(track), "insert": .int(slot),
                "plugin": .string(plugin), "mode": .string("duplicate_applyback"),
            ]
            if let path = await AppleScriptChannel.currentDocumentPath() { params["project_expected_path"] = .string(path) }
            let reply = await call("logic_plugins", "insert_verified", params, deps)
            // Inserting opens the plug-in's editor, a window titled after the track, which can
            // cover the Mixer strips the next steps click. Closing it changes nothing in the project.
            let closed = closeWindows(titled: track)
            if reply["state"] as? String == "A" {
                var accepted = outcome(reply, keys: ["observed_slot"])
                accepted = Outcome(state: accepted.state, accepted: true, detail: accepted.detail.merging(["editor_windows_closed": closed]) { a, _ in a })
                return accepted
            }
            // The insert path's own readback can lose the race with the editor window it opens;
            // an independent inventory read of the same slot is the readback then.
            guard reply["write_attempted"] as? Bool != false else { return outcome(reply, keys: ["what_was_observed"]) }
            let wanted = VerifiedPluginCatalog.canonicalPluginID(from: plugin)
            let inventory = await call("logic_plugins", "get_inventory", ["track": .int(index)], deps)
            let landed = (inventory["plugins"] as? [[String: Any]] ?? []).first { ($0["insert"] as? Int) == slot }
            if let landed, let id = landed["plugin_id"] as? String, id == wanted {
                return Outcome(state: "A", accepted: true, detail: [
                    "verify_source": "independent_inventory", "slot_name": landed["name"] ?? NSNull(),
                    "editor_windows_closed": closed,
                    "insert_reply_state": reply["state"] ?? NSNull(), "insert_reply_error": reply["error"] ?? NSNull(),
                ])
            }
            return outcome(reply, keys: ["what_was_observed"])

        case let .setSendLevel(from, bus, level):
            // Measured: Logic keeps the send editor's focus custody only with the source track selected.
            if let index = trackIndex(from, deps) {
                _ = await call("logic_tracks", "select", ["index": .int(index)], deps)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard let target = await sendSlot(from: from, bus: bus, deps) else {
                return refused("no occupied send from '\(from)' to Bus \(bus) read in logic://mixer")
            }
            let reply = await call("logic_mixer", "set_send_level_verified", [
                "target_ref": .string(target.ref), "ordinal": .int(target.ordinal),
                "level_db": .string(formatLevel(level)), "expected_current": .string(target.current),
            ], deps)
            return outcome(reply, keys: ["level_db", "before"])
        }
    }

    // MARK: - Reads

    private static func liveTrackNames(_ deps: HandlerDependencies) -> [String]? {
        guard let names = deps.liveTrackNamesReader(), !names.isEmpty,
              Set(names.keys) == Set(0..<names.count) else { return nil }
        return (0..<names.count).map { names[$0]! }
    }

    private static func trackIndex(_ name: String, _ deps: HandlerDependencies) -> Int? {
        guard let names = liveTrackNames(deps) else { return nil }
        let matches = names.indices.filter { names[$0].utf8.elementsEqual(name.utf8) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Show or hide the Mixer and read the result back through AX. `toggle_view` with `visible`
    /// refuses when it cannot observe its own UI custody, so the plain toggle is used and the
    /// Mixer area's presence is the readback.
    private static func ensureMixer(shown: Bool, _ deps: HandlerDependencies) async -> Bool {
        func isShown() -> Bool { AXLogicProElements.getMixerArea(runtime: .production) != nil }
        if isShown() == shown { return true }
        _ = await call("logic_navigate", "toggle_view", ["view": .string("mixer")], deps)
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if isShown() == shown { return true }
        }
        return false
    }

    /// Press the close button of every Logic window titled exactly `title` other than the main
    /// window (a plug-in editor is titled after its track). Returns how many were closed.
    private static func closeWindows(titled title: String) -> Int {
        guard let app = AXLogicProElements.appRoot(runtime: .production) else { return 0 }
        let main = AXLogicProElements.mainWindow(runtime: .production)
        let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute as String, runtime: .production) ?? []
        var closed = 0
        for window in windows where AXHelpers.getTitle(window, runtime: .production) == title {
            if let main, CFEqual(main, window) { continue }
            guard let button: AXUIElement = AXHelpers.getAttribute(window, kAXCloseButtonAttribute as String, runtime: .production) else { continue }
            if AXHelpers.performAction(button, kAXPressAction as String, runtime: .production) { closed += 1 }
        }
        if closed > 0 { usleep(300_000) }
        return closed
    }

    /// The strips of `logic://mixer`, read the way a client reads them (a fresh server process
    /// fills the Mixer cache only on such a read); nil when no strip read within a few seconds.
    private static func mixerStrips(_ deps: HandlerDependencies) async -> [[String: Any]]? {
        for _ in 0..<12 {
            _ = await deps.poller.refreshNow()
            if let result = try? await ResourceHandlers.read(uri: "logic://mixer", cache: deps.cache, router: deps.router,
                                                             targetRegistry: deps.targetRegistry),
               let text = result.contents.first?.text,
               let strips = decodedJSONObject(text)?["strips"] as? [[String: Any]], !strips.isEmpty {
                return strips
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return nil
    }

    private static func sendSlot(from: String, bus: Int, _ deps: HandlerDependencies) async -> (ref: String, ordinal: Int, current: String)? {
        for _ in 0..<5 {
            _ = await deps.poller.refreshNow()
            if let result = try? await ResourceHandlers.read(uri: "logic://mixer", cache: deps.cache, router: deps.router,
                                                             targetRegistry: deps.targetRegistry),
               let text = result.contents.first?.text,
               let object = decodedJSONObject(text),
               let strips = object["strips"] as? [[String: Any]],
               let strip = strips.first(where: { ($0["name"] as? String) == from }),
               let ref = strip["mixer_strip_ref"] as? String {
                for slot in strip["send_slots"] as? [[String: Any]] ?? [] where (slot["state"] as? String) != "observed_empty" {
                    let title = (slot["destination_display"] as? String) ?? (slot["checked_destination"] as? String) ?? ""
                    guard MixLayoutPlanner.busNumbers(in: [title]).contains(bus), let ordinal = slot["ordinal"] as? Int else { continue }
                    let current = ((slot["level_description"] as? String) ?? "-∞").replacingOccurrences(of: ",", with: ".")
                    return (ref, ordinal, current)
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    static func formatLevel(_ level: Double) -> String {
        level == level.rounded() ? String(Int(level)) : String(format: "%.1f", level)
    }

    // MARK: - Plumbing

    private static func call(_ tool: String, _ command: String, _ params: [String: Value],
                             _ deps: HandlerDependencies) async -> [String: Any] {
        guard let handler = OperationHandlerRegistry.handler(tool: tool, command: command) else {
            return ["state": "C", "error": "handler_missing", "hint": "\(tool).\(command) is not registered"]
        }
        let result = await handler(deps, params)
        guard case .text(let text, _, _)? = result.content.first else {
            return ["state": "C", "error": "no_text_reply"]
        }
        return decodedJSONObject(text) ?? ["state": result.isError == true ? "C" : "A", "message": text]
    }

    private static func jsonText(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func reply(_ record: Record, duplicate: Bool) -> CallTool.Result {
        let results = record.results.compactMap(decodedJSONObject)
        var extras: [String: Any] = [
            "mode": "execute",
            "idempotency_key": record.key,
            "plan_hash": record.planHash,
            "status": record.status.rawValue,
            "steps_done": record.next,
            "step_count": record.steps.count,
            "results": results,
            "receivers": record.receivers,
            "duplicate": duplicate,
            "write_attempted": !results.isEmpty,
        ]
        switch record.status {
        case .inProgress:
            extras["remaining"] = record.steps[record.next...].map(\.json)
            return toolTextResult(HonestContract.encodeStateB(reason: .readbackMismatch, extras: extras.merging([
                "reason": "mix_layout_in_progress",
                "hint": "Call execute again with the same idempotency_key and confirmed_plan_hash to continue.",
            ]) { _, new in new }))
        case .failed:
            extras["failure"] = record.failure ?? ""
            return refuse(.unsupportedState,
                "The layout stopped at the failed step (\(record.failure ?? "")). The steps before it stay applied; nothing was undone.",
                extras: extras)
        case .completed:
            let uncertain = results.filter { ($0["state"] as? String) != "A" }
            if uncertain.isEmpty { return toolTextResult(HonestContract.encodeStateA(extras: extras)) }
            extras["uncertain_steps"] = uncertain
            extras["reason"] = "steps_without_readback"
            extras["hint"] = "Every step ran; the listed ones answered State B (track colours have no AX readback; use color_readback project_file for State A)."
            return toolTextResult(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        }
    }
}
