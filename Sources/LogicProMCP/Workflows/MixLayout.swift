import CryptoKit
import Foundation
import MCP

/// The spec `logic_project.apply_mix_layout` takes: track order, subgroups, FX returns and sends.
///
/// ```json
/// { "order": ["Kick", "Snare"],
///   "groups": [{ "name": "DRUMS", "type": "bus", "color": "red", "members": ["Kick", "Snare"] }],
///   "fx_returns": [{ "name": "Plate", "plugins": ["ChromaVerb"], "color": "purple" }],
///   "sends": [{ "from": ["Snare"], "to": "Plate", "level_db": -12 }] }
/// ```
struct MixLayoutSpec: Equatable, Sendable {
    enum GroupType: String, CaseIterable, Sendable {
        /// The members' outputs go to a new bus; Logic creates the receiving aux, which becomes a track.
        case bus
        /// A summing track stack of the members (Track > Create Track Stack…).
        case summing
    }

    struct Group: Equatable, Sendable {
        let name: String
        let type: GroupType
        let color: String?
        let members: [String]
    }

    struct FXReturn: Equatable, Sendable {
        let name: String
        let plugins: [String]
        let color: String?
    }

    struct Send: Equatable, Sendable {
        let from: [String]
        let to: String
        let levelDB: Double
    }

    var order: [String] = []
    var groups: [Group] = []
    var fxReturns: [FXReturn] = []
    var sends: [Send] = []

    static let topLevelKeys: Set<String> = ["order", "groups", "fx_returns", "sends"]

    struct SpecError: Error, Equatable { let message: String }

    static func parse(_ value: Value?) -> Result<MixLayoutSpec, SpecError> {
        do {
            return .success(try parseThrowing(value))
        } catch let failure as SpecError {
            return .failure(failure)
        } catch {
            return .failure(SpecError(message: "\(error)"))
        }
    }

    private static func parseThrowing(_ value: Value?) throws -> MixLayoutSpec {
        func fail(_ message: String) -> SpecError { SpecError(message: message) }
        guard case .object(let object)? = value else { throw fail("'spec' must be an object") }
        let unknown = Set(object.keys).subtracting(topLevelKeys).sorted()
        guard unknown.isEmpty else { throw fail("unknown spec keys: \(unknown.joined(separator: ", "))") }
        func strings(_ value: Value?, _ what: String) throws -> [String] {
            guard let value else { return [] }
            guard case .array(let items) = value else { throw fail("\(what) must be an array of strings") }
            let names = items.compactMap(\.stringValue)
            guard names.count == items.count, !names.contains(where: { $0.isEmpty }) else {
                throw fail("\(what) must be an array of non-empty strings")
            }
            return names
        }
        func objects(_ key: String) throws -> [[String: Value]] {
            guard let value = object[key] else { return [] }
            guard case .array(let items) = value else { throw fail("'\(key)' must be an array of objects") }
            let rows = items.compactMap(\.objectValue)
            guard rows.count == items.count else { throw fail("'\(key)' must be an array of objects") }
            return rows
        }
        func name(_ row: [String: Value], _ what: String) throws -> String {
            guard let name = row["name"]?.stringValue, !name.isEmpty else { throw fail("\(what) needs a non-empty 'name'") }
            return name
        }
        func color(_ row: [String: Value], _ what: String) throws -> String? {
            guard let value = row["color"] else { return nil }
            guard let color = value.stringValue, !color.isEmpty else { throw fail("\(what) 'color' must be a string") }
            return color
        }
        func onlyKeys(_ row: [String: Value], _ allowed: Set<String>, _ what: String) throws {
            let unknownKeys = Set(row.keys).subtracting(allowed)
            guard unknownKeys.isEmpty else { throw fail("\(what) has unknown keys: \(unknownKeys.sorted().joined(separator: ", "))") }
        }
        var spec = MixLayoutSpec()
        spec.order = try strings(object["order"], "'order'")
        for (index, row) in try objects("groups").enumerated() {
            let what = "groups[\(index)]"
            try onlyKeys(row, ["name", "type", "color", "members"], what)
            let rawType = row["type"]?.stringValue ?? GroupType.bus.rawValue
            guard let type = GroupType(rawValue: rawType) else {
                throw fail("\(what) 'type' must be one of: \(GroupType.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let members = try strings(row["members"], "\(what) 'members'")
            guard !members.isEmpty else { throw fail("\(what) needs at least one member") }
            spec.groups.append(.init(name: try name(row, what), type: type, color: try color(row, what), members: members))
        }
        for (index, row) in try objects("fx_returns").enumerated() {
            let what = "fx_returns[\(index)]"
            try onlyKeys(row, ["name", "plugins", "color"], what)
            spec.fxReturns.append(.init(name: try name(row, what), plugins: try strings(row["plugins"], "\(what) 'plugins'"),
                                        color: try color(row, what)))
        }
        for (index, row) in try objects("sends").enumerated() {
            let what = "sends[\(index)]"
            try onlyKeys(row, ["from", "to", "level_db"], what)
            let from = try strings(row["from"], "\(what) 'from'")
            guard !from.isEmpty else { throw fail("\(what) needs at least one 'from' track") }
            guard let to = row["to"]?.stringValue, !to.isEmpty else { throw fail("\(what) needs 'to': an fx_returns name") }
            let level: Double
            switch row["level_db"] {
            case .int(let value)?: level = Double(value)
            case .double(let value)? where value.isFinite: level = value
            default: throw fail("\(what) needs a numeric 'level_db'")
            }
            spec.sends.append(.init(from: from, to: to, levelDB: level))
        }
        guard !(spec.order.isEmpty && spec.groups.isEmpty && spec.fxReturns.isEmpty && spec.sends.isEmpty) else {
            throw fail("the spec asks for nothing")
        }
        return spec
    }
}

/// Track-name matching for the layout: exact first, then case-insensitive; never a guess.
enum MixLayoutNames {
    enum Match: Equatable, Sendable {
        case exact(String)
        case caseInsensitive(String)
        case missing
        case ambiguous([String])
    }

    static func match(_ wanted: String, in names: [String]) -> Match {
        let exact = names.filter { $0.utf8.elementsEqual(wanted.utf8) }
        if exact.count == 1 { return .exact(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }
        let folded = names.filter { $0.caseInsensitiveCompare(wanted) == .orderedSame }
        switch folded.count {
        case 0: return .missing
        case 1: return .caseInsensitive(folded[0])
        default: return .ambiguous(folded)
        }
    }
}

/// One write the layout performs, in terms of names: indices are resolved from the live track list
/// immediately before each step, because every step can move rows.
enum MixLayoutStep: Equatable, Sendable {
    case moveTrack(name: String, after: String)
    case routeOutput(track: String, bus: Int, createReceiver: Bool, owner: String)
    case createSend(from: String, bus: Int, createReceiver: Bool, owner: String)
    /// The aux Logic created for `owner`'s bus becomes a track, then takes `owner`'s name. Logic
    /// inserts it after the selected track, so `after` (nil: the last track) is selected first.
    case createTrackForReceiver(owner: String, after: String?)
    case renameReceiverTrack(owner: String)
    /// Put a new group track directly after `after` when it landed below it; a track above its
    /// anchor cannot be moved down, and is left where Logic put it.
    case placeTrack(name: String, after: String)
    case summingStack(name: String, members: [String])
    case setColor(track: String, color: String)
    case insertPlugin(track: String, plugin: String, slot: Int)
    case setSendLevel(from: String, bus: Int, levelDB: Double)

    /// Whether the Mixer must be shown (true) or hidden (false) for this step; nil when either works.
    /// Steps that click track headers need the whole track list, which the Mixer covers in part.
    var mixerShown: Bool? {
        switch self {
        case .routeOutput, .createSend, .createTrackForReceiver, .insertPlugin, .setSendLevel: true
        case .moveTrack, .placeTrack, .summingStack, .setColor: false
        case .renameReceiverTrack: nil
        }
    }

    var json: [String: Any] {
        switch self {
        case let .moveTrack(name, after):
            ["step": "move_track", "name": name, "after": after]
        case let .routeOutput(track, bus, createReceiver, owner):
            ["step": "set_output", "track": track, "bus": bus, "create_receiver": createReceiver, "for": owner]
        case let .createSend(from, bus, createReceiver, owner):
            ["step": "create_send", "from": from, "bus": bus, "create_receiver": createReceiver, "for": owner]
        case let .createTrackForReceiver(owner, after):
            ["step": "create_track_for_receiver", "for": owner, "after": after ?? "(last track)"]
        case let .renameReceiverTrack(owner):
            ["step": "rename_receiver_track", "name": owner]
        case let .placeTrack(name, after):
            ["step": "place_track", "name": name, "after": after]
        case let .summingStack(name, members):
            ["step": "create_summing_stack", "name": name, "members": members]
        case let .setColor(track, color):
            ["step": "set_color", "track": track, "color": color]
        case let .insertPlugin(track, plugin, slot):
            ["step": "insert_plugin", "track": track, "plugin": plugin, "slot": slot]
        case let .setSendLevel(from, bus, level):
            ["step": "set_send_level", "from": from, "bus": bus, "level_db": level]
        }
    }
}

/// Pure preflight: the spec against the live track names and the buses already in use.
enum MixLayoutPlanner {
    struct Blocker: Equatable, Sendable {
        let code: String
        let detail: String
        var json: [String: Any] { ["code": code, "detail": detail] }
    }

    struct Plan: Sendable {
        let steps: [MixLayoutStep]
        let blockers: [Blocker]
        /// Spec name -> the track name it matched case-insensitively (exact matches are not listed).
        let caseInsensitiveMatches: [String: String]
        let buses: [String: Int]
        let hash: String
    }

    static func plan(
        spec: MixLayoutSpec,
        trackNames: [String],
        usedBuses: Set<Int>,
        pluginInsertable: (String) -> Bool = MixLayoutPlanner.stockPluginInsertable,
        colorKnown: (String) -> Bool = { if case .resolved = TrackColorPalette.resolve(name: $0) { true } else { false } }
    ) -> Plan {
        var blockers: [Blocker] = []
        var folded: [String: String] = [:]
        func resolve(_ wanted: String, _ context: String) -> String? {
            switch MixLayoutNames.match(wanted, in: trackNames) {
            case .exact(let name):
                return name
            case .caseInsensitive(let name):
                folded[wanted] = name
                return name
            case .missing:
                blockers.append(.init(code: "track_not_found", detail: "\(context): no track is named '\(wanted)'"))
            case .ambiguous(let names):
                blockers.append(.init(code: "track_ambiguous",
                    detail: "\(context): '\(wanted)' matches \(names.count) tracks (\(names.joined(separator: ", "))); rename them so it names one"))
            }
            return nil
        }
        var steps: [MixLayoutStep] = []
        // Colours go last, together: they click track headers, so the Mixer is hidden once for all.
        var colorSteps: [MixLayoutStep] = []

        // New names: unique among themselves and unlike every existing track.
        let newNames = spec.groups.map(\.name) + spec.fxReturns.map(\.name)
        var seen: [String] = []
        for name in newNames {
            if seen.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                blockers.append(.init(code: "name_conflict", detail: "'\(name)' is used for more than one group or FX return"))
            }
            seen.append(name)
            if MixLayoutNames.match(name, in: trackNames) != .missing {
                blockers.append(.init(code: "name_conflict", detail: "a track named '\(name)' already exists"))
            }
        }
        for (owner, color) in spec.groups.map({ ($0.name, $0.color) }) + spec.fxReturns.map({ ($0.name, $0.color) }) {
            if let color, !colorKnown(color) {
                blockers.append(.init(code: "unknown_color", detail: "\(owner): '\(color)' is not a palette colour name"))
            }
        }

        // 1. Order: upward moves only, so the first listed track must already be the topmost listed.
        if !spec.order.isEmpty {
            let resolved = spec.order.compactMap { resolve($0, "order") }
            let duplicates = Dictionary(grouping: resolved, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
            if !duplicates.isEmpty {
                blockers.append(.init(code: "order_duplicate", detail: "order lists \(duplicates.joined(separator: ", ")) more than once"))
            } else if resolved.count == spec.order.count {
                let current = trackNames.filter { resolved.contains($0) }
                if let moves = TrackMoveVerifier.plan(current: current, target: resolved) {
                    steps += moves.map { .moveTrack(name: $0.name, after: $0.after) }
                } else {
                    blockers.append(.init(code: "order_needs_top_move",
                        detail: "'\(resolved[0])' must already sit above every other listed track (now '\(current.first ?? "")' does): tracks can only be moved up to directly after another track, never to the very top"))
                }
            }
        }

        // 2. Buses: the lowest numbers no strip uses, one per bus group and FX return.
        var free = (1...256).filter { !usedBuses.contains($0) }.makeIterator()
        var buses: [String: Int] = [:]
        for name in spec.groups.filter({ $0.type == .bus }).map(\.name) + spec.fxReturns.map(\.name) {
            buses[name] = free.next()
        }

        // 3. Groups.
        var grouped: [String: String] = [:]
        for group in spec.groups {
            let members = group.members.compactMap { resolve($0, "group \(group.name)") }
            guard members.count == group.members.count else { continue }
            for member in members {
                if let other = grouped[member] {
                    blockers.append(.init(code: "member_in_two_groups", detail: "'\(member)' is in both \(other) and \(group.name)"))
                }
                grouped[member] = group.name
            }
            switch group.type {
            case .bus:
                guard let bus = buses[group.name] else { continue }
                for (index, member) in members.enumerated() {
                    steps.append(.routeOutput(track: member, bus: bus, createReceiver: index == 0, owner: group.name))
                }
                steps += [.createTrackForReceiver(owner: group.name, after: members[members.count - 1]),
                          .renameReceiverTrack(owner: group.name),
                          .placeTrack(name: group.name, after: members[members.count - 1])]
            case .summing:
                steps.append(.summingStack(name: group.name, members: members))
            }
            if let color = group.color {
                colorSteps += ([group.name] + members).map { .setColor(track: $0, color: color) }
            }
        }

        // 4. FX returns, each created by its first send.
        var pairs: [(from: String, fx: String, level: Double)] = []
        for (index, send) in spec.sends.enumerated() {
            guard let fx = spec.fxReturns.first(where: { $0.name.caseInsensitiveCompare(send.to) == .orderedSame }) else {
                blockers.append(.init(code: "send_target_unknown", detail: "sends[\(index)]: '\(send.to)' is not an fx_returns name"))
                continue
            }
            if !(-144...6).contains(send.levelDB) {
                blockers.append(.init(code: "send_level_out_of_range", detail: "sends[\(index)]: \(send.levelDB) dB is outside -144…+6"))
            }
            for source in send.from {
                guard let from = resolve(source, "sends[\(index)]") else { continue }
                if pairs.contains(where: { $0.from == from && $0.fx == fx.name }) {
                    blockers.append(.init(code: "send_duplicate", detail: "'\(from)' sends to \(fx.name) twice"))
                }
                pairs.append((from, fx.name, send.levelDB))
            }
        }
        for fx in spec.fxReturns {
            for plugin in fx.plugins where !pluginInsertable(plugin) {
                blockers.append(.init(code: "plugin_not_insertable",
                    detail: "\(fx.name): '\(plugin)' is not a stock effect whose slot name has been measured for readback"))
            }
            guard let bus = buses[fx.name] else { continue }
            guard let first = pairs.first(where: { $0.fx == fx.name }) else {
                blockers.append(.init(code: "fx_return_without_send", detail: "\(fx.name): no send goes to it, and the return is created by its first send"))
                continue
            }
            steps += [.createSend(from: first.from, bus: bus, createReceiver: true, owner: fx.name),
                      .createTrackForReceiver(owner: fx.name, after: nil), .renameReceiverTrack(owner: fx.name)]
            if let color = fx.color { colorSteps.append(.setColor(track: fx.name, color: color)) }
            steps += fx.plugins.enumerated().map { .insertPlugin(track: fx.name, plugin: $0.element, slot: $0.offset) }
            for pair in pairs.filter({ $0.fx == fx.name }).dropFirst() {
                steps.append(.createSend(from: pair.from, bus: bus, createReceiver: false, owner: fx.name))
            }
        }
        for pair in pairs {
            if let bus = buses[pair.fx] { steps.append(.setSendLevel(from: pair.from, bus: bus, levelDB: pair.level)) }
        }
        steps += colorSteps
        if buses.count < (spec.groups.filter { $0.type == .bus }.count + spec.fxReturns.count) {
            blockers.append(.init(code: "no_free_bus", detail: "not enough unused buses"))
        }

        let hashInput: [String: Any] = ["tracks": trackNames, "steps": steps.map(\.json), "blockers": blockers.map(\.json)]
        let encoded = (try? JSONSerialization.data(withJSONObject: hashInput, options: [.sortedKeys])) ?? Data()
        let hash = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        return Plan(steps: steps, blockers: blockers, caseInsensitiveMatches: folded, buses: buses, hash: hash)
    }

    /// A stock effect insert_verified can both insert and read back.
    static func stockPluginInsertable(_ alias: String) -> Bool {
        guard let id = VerifiedPluginCatalog.canonicalPluginID(from: alias) else { return false }
        return AccessibilityChannel.insertableAllowlist.contains(id)
    }

    /// Bus numbers named in a strip's input, output or send titles (`Bus 6`, `Bus 6 → Aux 1`).
    static func busNumbers(in titles: [String]) -> Set<Int> {
        var found: Set<Int> = []
        for title in titles {
            var rest = Substring(title)
            while let range = rest.range(of: "Bus ") {
                let digits = rest[range.upperBound...].prefix { $0.isNumber }
                if let number = Int(digits) { found.insert(number) }
                rest = rest[range.upperBound...]
            }
        }
        return found
    }
}
