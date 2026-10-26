import ApplicationServices
import Foundation

/// `track.move_verified`: place one track directly after another track that sits above it.
///
/// Logic 12.4 exposes no way to move a track through AX (header rows have no settable position and
/// no move action) and has no Move Track key command. Measured instead (`research/FINDINGS.md` §5):
/// a folder stack made of the anchor and the track gathers the two at the anchor's position in
/// track order, and Track > Flatten Stack removes the stack's main track again, leaving the track
/// right after the anchor and every other track in its order. Both steps are the verified
/// `create_stack` path and a menu press; the whole rail is read back after each.
///
/// Only upward moves exist this way, so nothing can be moved to the very top: that would need a
/// drag of the header, which is not done here.
extension AccessibilityChannel {
    static func defaultMoveTrack(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        var evidence: [String: Any] = ["operation": "track.move_verified", "write_attempted": false]
        func refuse(_ error: HonestContract.FailureError, _ reason: String, _ hint: String) -> ChannelResult {
            evidence["reason"] = reason
            return .error(HonestContract.encodeStateC(error: error, hint: hint, extras: evidence))
        }
        guard let name = params["name"], !name.isEmpty, let anchor = params["after"], !anchor.isEmpty else {
            return refuse(.invalidParams, "params_missing", "move_track requires 'name' (the track to move) and 'after' (the track it should follow)")
        }
        guard name != anchor else {
            return refuse(.invalidParams, "same_track", "'name' and 'after' are the same track")
        }
        evidence["name"] = name
        evidence["after"] = anchor

        guard case .read(let before) = trackStackRailRead(runtime: runtime) else {
            return refuse(.readbackUnavailable, "rail_unreadable", "The track list could not be read completely; nothing was changed.")
        }
        let beforeNames = before.map(\.name)
        evidence["before_order"] = beforeNames
        let indices: [Int]
        switch TrackStackVerifier.resolveMembers([anchor, name], in: beforeNames) {
        case .resolved(let found):
            indices = found
        case .missing(let names):
            evidence["missing"] = names
            return refuse(.elementNotFound, "track_not_found", "No track is named \(names.joined(separator: ", ")).")
        case .ambiguous(let names):
            evidence["ambiguous"] = names
            return refuse(.ambiguousTargetName, "track_ambiguous",
                "More than one track is named \(names.joined(separator: ", ")); rename them so each is unique.")
        case .duplicateMembers, .tooFew:
            return refuse(.invalidParams, "same_track", "'name' and 'after' are the same track")
        }
        let anchorIndex = beforeNames.firstIndex { $0.utf8.elementsEqual(anchor.utf8) }!
        let moveIndex = beforeNames.firstIndex { $0.utf8.elementsEqual(name.utf8) }!
        evidence["from_index"] = moveIndex
        if let stack = indices.first(where: { before[$0].isStackHeader != false }) {
            return refuse(.unsupportedState, "stack_involved",
                "'\(beforeNames[stack])' is a stack main track (or its stack state did not read); stacks are not moved here.")
        }
        guard anchorIndex < moveIndex else {
            return refuse(.unsupportedState, "anchor_below",
                "'\(anchor)' is below '\(name)'. Only upward moves are possible (stack + flatten): move the tracks between them up instead, or place '\(anchor)' first.")
        }
        let expected = TrackMoveVerifier.expectedAfter(before: beforeNames, moving: moveIndex, after: anchorIndex)
        evidence["expected_order"] = expected
        if moveIndex == anchorIndex + 1 {
            evidence["already_in_place"] = true
            evidence["after_order"] = beforeNames
            return .success(HonestContract.encodeStateA(extras: evidence))
        }

        // 1. The anchor and the track as a folder stack: the verified create_stack path.
        let membersJSON = (try? String(data: JSONEncoder().encode([anchor, name]), encoding: .utf8)) ?? "[]"
        let stacked = await defaultCreateTrackStack(params: ["kind": "folder", "members_json": membersJSON], runtime: runtime)
        guard case .success(let stackJSON) = stacked,
              let stackReply = (try? JSONSerialization.jsonObject(with: Data(stackJSON.utf8))) as? [String: Any],
              stackReply["state"] as? String == "A" else {
            evidence["stack_reply"] = stacked.message
            if case .error = stacked {
                return refuse(.unsupportedState, "stack_refused", "The temporary folder stack was not created; nothing was moved.")
            }
            evidence["write_attempted"] = true
            evidence["hint"] = "The temporary folder stack did not read back as expected. Check the track list; Edit > Undo removes it."
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: evidence))
        }
        evidence["write_attempted"] = true
        evidence["stack_name"] = stackReply["stack_name"] ?? NSNull()
        evidence["stack_selected_alone"] = stackReply["stack_selected_alone"] ?? NSNull()

        // 2. Track > Flatten Stack on the selected stack main track.
        func leftStacked(_ reason: String, _ hint: String) -> ChannelResult {
            evidence["reason"] = reason
            evidence["hint"] = hint + " The temporary folder stack is still there; Track > Flatten Stack (or Edit > Undo) removes it."
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: evidence))
        }
        guard case .found(let item) = AXLogicProElements.menuItemRead(
            labelPath: [AXLocalePolicy.flattenStackMenuPath.bar, AXLocalePolicy.flattenStackMenuPath.item],
            runtime: runtime
        ) else {
            return leftStacked("flatten_menu_absent", "Track > Flatten Stack was not found.")
        }
        let enabled: Bool? = AXHelpers.getAttribute(item, kAXEnabledAttribute as String, runtime: runtime.ax)
        guard enabled == true else {
            return leftStacked("flatten_menu_disabled", "Track > Flatten Stack is not enabled for the selection.")
        }
        _ = AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax)

        // 3. The whole rail: exactly the expected order, no stack main track left.
        var after: [String] = []
        for _ in 0..<20 {
            usleep(100_000)
            guard case .read(let rows) = trackStackRailRead(runtime: runtime) else { continue }
            after = rows.map(\.name)
            if after == expected { break }
        }
        evidence["after_order"] = after
        guard after == expected else {
            return leftStacked("order_mismatch", "The track list does not read as '\(name)' directly after '\(anchor)'.")
        }
        evidence["to_index"] = anchorIndex + 1
        return .success(HonestContract.encodeStateA(extras: evidence))
    }
}
