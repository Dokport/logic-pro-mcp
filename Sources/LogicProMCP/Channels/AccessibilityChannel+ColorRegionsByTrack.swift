import ApplicationServices
import Foundation

/// `tracks.color_regions_by_track`: every region takes its track's colour.
///
/// Logic's own command (measured on 12.4): Edit > Select All with the Tracks area focused selects
/// every region, and the Tracks area's Functions > Color Regions/Cells by Track Color colours each
/// selected region like its track. Colouring regions one track at a time through View > Colors
/// coloured only one region per track on a real session, so this is the path for "regions match
/// their tracks". There is no AX colour read, so the answer is State B with the Undo-title witness.
extension AccessibilityChannel {
    static func defaultColorRegionsByTrack(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        var evidence: [String: Any] = ["operation": "track.color_regions_by_track", "write_attempted": false]
        func refuse(_ error: HonestContract.FailureError, _ reason: String, _ hint: String) -> ChannelResult {
            evidence["reason"] = reason
            return .error(HonestContract.encodeStateC(error: error, hint: hint, extras: evidence))
        }
        guard let header = AXLogicProElements.findTrackHeader(at: 0, runtime: runtime) else {
            return refuse(.elementNotFound, "track_list_unreadable", "No track header was found; nothing was changed.")
        }
        let front = FrontmostGate.prepareObserved(
            observe: runtime.observeFrontmost,
            activate: { ProcessUtils.activateLogicPro() },
            sleepMicros: { usleep($0) }
        )
        guard front.preparation.isReady else {
            return refuse(.unsupportedState, "logic_not_frontmost", "Logic Pro could not be brought to the front; nothing was changed.")
        }

        // 1. Every region selected: Edit > Select All (locale-free identifier), read back on the
        // regions the arrangement shows.
        guard let selectAll = AXLogicProElements.menuItem(identifier: "selectAll:", inMenuBar: AXLocalePolicy.editMenuBar, runtime: runtime) else {
            return refuse(.elementNotFound, "select_all_absent", "Edit > Select All was not found; nothing was changed.")
        }
        _ = AXHelpers.performAction(selectAll, kAXPressAction as String, runtime: runtime.ax)
        usleep(250_000)
        guard case .success(let arrangement) = enumerateRegionItems(runtime: runtime),
              let selected = selectedRegionInfos(runtime: runtime) else {
            return refuse(.readbackUnavailable, "regions_unreadable", "The arrangement's regions could not be read; nothing was coloured.")
        }
        evidence["visible_regions"] = arrangement.regions.count
        evidence["selected_regions"] = selected.count
        evidence["region_items_outside_viewport"] = arrangement.regionItemsOutsideViewport
        guard !arrangement.regions.isEmpty, selected.count == arrangement.regions.count else {
            return refuse(.unsupportedState, "selection_not_all",
                "Select All did not read back as every visible region selected (the Tracks area may not have had focus); nothing was coloured.")
        }

        // 2. Functions > Color Regions/Cells by Track Color.
        let row = tracksAreaMenuRow(anchor: header, runtime: runtime)
        guard row.count >= 3 else {
            return refuse(.elementNotFound, "functions_menu_not_found", "The Tracks area's Functions menu button was not found; nothing was coloured.")
        }
        let functions = row[1]
        _ = AXHelpers.performAction(functions, kAXPressAction as String, runtime: runtime.ax)
        var items: [AXUIElement] = []
        for _ in 0..<10 {
            usleep(100_000)
            items = AXHelpers.findAllDescendants(of: functions, role: kAXMenuItemRole as String, maxDepth: 4, runtime: runtime.ax)
                .filter { AXLocalePolicy.colorRegionsByTrackColorMenuItem.matches(AXHelpers.getTitle($0, runtime: runtime.ax)) }
            if !items.isEmpty { break }
        }
        guard items.count == 1 else {
            AXMouseHelper.pressEscape()
            return refuse(.elementNotFound, "menu_item_absent", "Functions does not offer Color Regions/Cells by Track Color; nothing was coloured.")
        }
        let enabled: Bool? = AXHelpers.getAttribute(items[0], kAXEnabledAttribute as String, runtime: runtime.ax)
        guard enabled == true else {
            AXMouseHelper.pressEscape()
            return refuse(.unsupportedState, "menu_item_disabled", "Color Regions/Cells by Track Color is not enabled; nothing was coloured.")
        }
        _ = AXHelpers.performAction(items[0], kAXPressAction as String, runtime: runtime.ax)
        evidence["write_attempted"] = true
        usleep(300_000)

        // 3. The Undo title is the witness; then the selection is cleared again.
        let witness = readTrackColorUndoWitness(runtime: runtime)
        evidence["undo_title"] = witness.title ?? NSNull()
        if let deselect = AXLogicProElements.menuItem(identifier: "deselectAll:", inMenuBar: AXLocalePolicy.editMenuBar, runtime: runtime) {
            _ = AXHelpers.performAction(deselect, kAXPressAction as String, runtime: runtime.ax)
        }
        let named = witness.title.map { AXLocalePolicy.colorRegionsUndoOperation.containsAny(in: $0) } ?? false
        guard named else {
            evidence["hint"] = "The command was pressed, but the Undo title does not name a region colour change."
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: evidence))
        }
        evidence["undo_witness"] = "color_regions"
        evidence["hint"] = "Region colour is not readable through Accessibility; the Undo title names the change."
        return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: evidence))
    }
}
