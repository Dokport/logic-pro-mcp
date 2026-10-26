import ApplicationServices
import Foundation

/// `track.reorder_verified`: put the top-level tracks (stacks count as one, with their members)
/// in a given order by dragging track headers.
///
/// Measured on Logic 12.4 (test project, 2026-10-26): a CGEvent drag from a header's free area
/// right of the name to the top edge of another row moves the track to just above that row, up
/// or down, and a stack header carries its members. Logic shows no stack membership in the
/// headers, so a track dropped right under an open stack could land inside it unseen. Every
/// open stack is therefore closed first (its members stop being rows; the rows that disappear
/// are recorded as its members), only top-level rows are dragged, the order is read back after
/// each drag, and the stacks are opened again. State A needs the whole track list read back as
/// each top-level track in the requested order, each opened stack followed by exactly its own
/// members. A coordinate drag is the only channel: AX exposes no move action on headers.
extension AccessibilityChannel {
    static func defaultReorderTracks(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        var evidence: [String: Any] = ["operation": "track.reorder_verified", "write_attempted": false]
        func refuse(_ error: HonestContract.FailureError, _ reason: String, _ hint: String) -> ChannelResult {
            evidence["reason"] = reason
            return .error(HonestContract.encodeStateC(error: error, hint: hint, extras: evidence))
        }
        guard let raw = params["order_json"], let requested = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)),
              !requested.isEmpty else {
            return refuse(.invalidParams, "order_invalid", "reorder_tracks requires 'order': the top-level track names in the wanted order")
        }
        guard case .read(let before) = trackStackRailRead(runtime: runtime),
              !before.contains(where: { $0.isStackHeader == nil }) else {
            return refuse(.readbackUnavailable, "rail_unreadable", "The track list (or a row's stack state) could not be read; nothing was changed.")
        }
        evidence["before_order"] = before.map(\.name)
        let front = FrontmostGate.prepareObserved(
            observe: runtime.observeFrontmost,
            activate: { ProcessUtils.activateLogicPro() },
            sleepMicros: { usleep($0) }
        )
        guard front.preparation.isReady else {
            return refuse(.unsupportedState, "logic_not_frontmost", "Logic Pro could not be brought to the front; nothing was changed.")
        }

        // 1. Close every open stack, recording the rows that disappear as its members.
        var members: [String: [String]] = [:]
        var reopened: [String] = []
        for _ in 0..<64 {
            guard case .read(let rows) = trackStackRailRead(runtime: runtime) else {
                return reorderRestore(reopened, members, evidence, "rail_unreadable", "The track list stopped reading while closing stacks.", runtime)
            }
            guard let open = rows.first(where: { $0.isStackHeader == true && reorderDisclosure($0.header, runtime: runtime)?.open == true }) else { break }
            guard let disclosure = reorderDisclosure(open.header, runtime: runtime) else { break }
            let namesBefore = rows.map(\.name)
            guard reorderToggle(disclosure.element, runtime: runtime) else {
                return reorderRestore(reopened, members, evidence, "disclosure_not_visible",
                    "Stack '\(open.name)''s disclosure arrow is not on screen.", runtime)
            }
            guard case .read(let after) = trackStackRailRead(runtime: runtime) else {
                return reorderRestore(reopened, members, evidence, "rail_unreadable", "The track list stopped reading while closing stacks.", runtime)
            }
            let namesAfter = after.map(\.name)
            evidence["close_attempt"] = ["stack": open.name, "before": namesBefore, "after": namesAfter]
            guard let at = namesBefore.firstIndex(of: open.name), namesAfter.count < namesBefore.count,
                  Array(namesBefore[..<(at + 1)]) == Array(namesAfter[..<(at + 1)]) else {
                return reorderRestore(reopened, members, evidence, "stack_close_unrecognized",
                    "Closing stack '\(open.name)' did not remove a run of rows directly under it.", runtime)
            }
            let removed = namesBefore.count - namesAfter.count
            members[open.name] = Array(namesBefore[(at + 1)...(at + removed)])
            reopened.append(open.name)
        }
        evidence["closed_stacks"] = reopened
        evidence["write_attempted"] = !reopened.isEmpty

        // 2. The requested order against the top-level rows: exact, then case-insensitive, never a guess.
        guard case .read(let topRows) = trackStackRailRead(runtime: runtime) else {
            return reorderRestore(reopened, members, evidence, "rail_unreadable", "The top-level track list could not be read.", runtime)
        }
        var top = topRows.map(\.name)
        evidence["top_level_before"] = top
        guard Set(top).count == top.count else {
            return reorderRestore(reopened, members, evidence, "top_level_names_not_unique",
                "Two top-level tracks share a name; rename them so each is unique.", runtime)
        }
        var target: [String] = []
        for name in requested {
            switch MixLayoutNames.match(name, in: top) {
            case .exact(let found), .caseInsensitive(let found): target.append(found)
            case .missing:
                return reorderRestore(reopened, members, evidence, "track_not_found", "No top-level track is named '\(name)'.", runtime)
            case .ambiguous(let found):
                return reorderRestore(reopened, members, evidence, "track_ambiguous", "'\(name)' matches \(found.joined(separator: ", ")).", runtime)
            }
        }
        guard Set(target).count == target.count, Set(target) == Set(top) else {
            return reorderRestore(reopened, members, evidence, "order_not_a_permutation",
                "'order' must name every top-level track exactly once: \(top.joined(separator: ", ")).", runtime)
        }
        evidence["requested_order"] = target

        // 3. One drag per misplaced row, top down; every drag is upward onto row p's top edge.
        var drags = 0
        for position in target.indices where top[position] != target[position] {
            guard case .read(let rows) = trackStackRailRead(runtime: runtime),
                  rows.map(\.name) == top,
                  let from = top.firstIndex(of: target[position]),
                  let grip = reorderGrip(rows[from].header, runtime: runtime),
                  let drop = reorderDropPoint(rows[position].header, x: grip.x, runtime: runtime) else {
                return reorderRestore(reopened, members, evidence, "row_not_visible",
                    "'\(target[position])' or its destination is not fully visible in the track list; scroll or enlarge the window.", runtime)
            }
            evidence["write_attempted"] = true
            AXMouseHelper.drag(from: grip, to: drop)
            drags += 1
            usleep(400_000)
            var expected = top
            expected.remove(at: from)
            expected.insert(target[position], at: position)
            var observed: [String] = []
            for _ in 0..<10 {
                if case .read(let after) = trackStackRailRead(runtime: runtime) { observed = after.map(\.name) }
                if observed == expected { break }
                usleep(150_000)
            }
            guard observed == expected else {
                evidence["drags"] = drags
                evidence["observed_top_level"] = observed
                return reorderRestore(reopened, members, evidence, "drag_result_mismatch",
                    "After dragging '\(target[position])' the top-level order is not the expected one.", runtime, uncertain: true)
            }
            top = expected
        }
        evidence["drags"] = drags

        // 4. Open the stacks again; the whole list must be each track followed by its own members.
        let restored = reorderReopen(reopened, runtime: runtime)
        evidence["reopened_stacks"] = restored
        let expectedFull = target.flatMap { [$0] + (members[$0] ?? []) }
        var full: [String] = []
        for _ in 0..<10 {
            if case .read(let rows) = trackStackRailRead(runtime: runtime) { full = rows.map(\.name) }
            if full == expectedFull { break }
            usleep(150_000)
        }
        evidence["after_order"] = full
        guard full == expectedFull, restored.count == reopened.count else {
            evidence["expected_order"] = expectedFull
            evidence["hint"] = "The tracks were dragged; the track list read back with the stacks reopened is not the expected one."
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: evidence))
        }
        return .success(HonestContract.encodeStateA(extras: evidence))
    }

    private static func reorderDisclosure(_ header: AXUIElement, runtime: AXLogicProElements.Runtime) -> (element: AXUIElement, open: Bool)? {
        guard let triangle = AXHelpers.findDescendant(of: header, role: kAXDisclosureTriangleRole as String, maxDepth: 3, runtime: runtime.ax) else {
            return nil
        }
        let value = (AXHelpers.getValue(triangle, runtime: runtime.ax) as? NSNumber)?.intValue
        return (triangle, value == 1)
    }

    /// Measured on 12.4: AXPress on a stack's disclosure arrow does nothing (its AXValue is not
    /// settable either); a click on its AX frame opens or closes the stack.
    private static func reorderToggle(_ triangle: AXUIElement, runtime: AXLogicProElements.Runtime) -> Bool {
        guard let origin = AXHelpers.getPosition(triangle, runtime: runtime.ax),
              let size = AXHelpers.getSize(triangle, runtime: runtime.ax), size.width > 0, size.height > 0 else { return false }
        AXMouseHelper.click(at: CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2))
        usleep(400_000)
        return true
    }

    /// The press point: the header's free area right of its name, as the stack selection uses.
    private static func reorderGrip(_ header: AXUIElement, runtime: AXLogicProElements.Runtime) -> CGPoint? {
        guard let field = AXHelpers.getChildren(header, runtime: runtime.ax)
            .first(where: { AXHelpers.getRole($0, runtime: runtime.ax) == kAXTextFieldRole as String }),
              let origin = AXHelpers.getPosition(field, runtime: runtime.ax),
              let size = AXHelpers.getSize(field, runtime: runtime.ax),
              reorderRowVisible(header, runtime: runtime) else { return nil }
        return CGPoint(x: origin.x + size.width - 30, y: origin.y + size.height / 2)
    }

    /// Two points below the destination row's top edge: the drop lands just above that row.
    private static func reorderDropPoint(_ header: AXUIElement, x: CGFloat, runtime: AXLogicProElements.Runtime) -> CGPoint? {
        guard let origin = AXHelpers.getPosition(header, runtime: runtime.ax), reorderRowVisible(header, runtime: runtime) else { return nil }
        return CGPoint(x: x, y: origin.y + 2)
    }

    private static func reorderRowVisible(_ header: AXUIElement, runtime: AXLogicProElements.Runtime) -> Bool {
        guard let origin = AXHelpers.getPosition(header, runtime: runtime.ax),
              let size = AXHelpers.getSize(header, runtime: runtime.ax) else { return false }
        var ancestor: AXUIElement? = AXHelpers.getAttribute(header, kAXParentAttribute as String, runtime: runtime.ax)
        while let current = ancestor, AXHelpers.getRole(current, runtime: runtime.ax) != kAXScrollAreaRole as String {
            ancestor = AXHelpers.getAttribute(current, kAXParentAttribute as String, runtime: runtime.ax)
        }
        guard let scroll = ancestor, let scrollOrigin = AXHelpers.getPosition(scroll, runtime: runtime.ax),
              let scrollSize = AXHelpers.getSize(scroll, runtime: runtime.ax) else { return false }
        return CGRect(origin: scrollOrigin, size: scrollSize).contains(CGRect(origin: origin, size: size))
    }

    /// Open the named stacks again; returns those that read open afterwards.
    private static func reorderReopen(_ names: [String], runtime: AXLogicProElements.Runtime) -> [String] {
        var opened: [String] = []
        for name in names {
            guard case .read(let rows) = trackStackRailRead(runtime: runtime),
                  let row = rows.first(where: { $0.name == name }),
                  let disclosure = reorderDisclosure(row.header, runtime: runtime) else { continue }
            if !disclosure.open { _ = reorderToggle(disclosure.element, runtime: runtime) }
            if case .read(let after) = trackStackRailRead(runtime: runtime),
               let again = after.first(where: { $0.name == name }),
               reorderDisclosure(again.header, runtime: runtime)?.open == true {
                opened.append(name)
            }
        }
        return opened
    }

    /// A refusal after stacks may have been closed: they are opened again first. Nothing was
    /// dragged unless `uncertain`, so the order is unchanged and the answer is State C.
    private static func reorderRestore(
        _ reopened: [String], _ members: [String: [String]], _ evidence: [String: Any],
        _ reason: String, _ hint: String, _ runtime: AXLogicProElements.Runtime, uncertain: Bool = false
    ) -> ChannelResult {
        var details = evidence
        details["reason"] = reason
        details["reopened_stacks"] = reorderReopen(reopened, runtime: runtime)
        if uncertain {
            details["hint"] = hint + " Check the track list; Edit > Undo reverts the last drag."
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: details))
        }
        return .error(HonestContract.encodeStateC(error: .unsupportedState, hint: hint + " Nothing was moved.", extras: details))
    }
}
