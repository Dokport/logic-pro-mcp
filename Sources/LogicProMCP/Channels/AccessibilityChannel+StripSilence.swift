import ApplicationServices
import Foundation

/// `track.strip_silence`: Remove Silence from Audio Region… on every audio region of one track.
///
/// Measured on Logic 12.4 (2026-10-26, `research/ax/remove-silence-dialog.txt`):
/// - the command is in the Tracks area's local Functions menu (the second of the menu buttons
///   at the left of the row above the track list), enabled once audio regions are selected;
/// - its window has four numeric fields (threshold, minimum silence, pre-attack, post-release, top
///   to bottom), each an `AXGroup` of segment sliders. Writing a segment's `AXValue` or stepping it
///   moves it unpredictably (-28 stepped once to -80). A double-click selects the whole field, the
///   value typed as Unicode characters replaces it, and Tab commits it; the field shows the
///   system's decimal mark and rejects the other one;
/// - a static text previews the result (`16 Regions`), and after OK the track holds exactly that
///   many regions and the Edit menu offers `Undo Strip`.
extension AccessibilityChannel {
    static func defaultStripSilence(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        var evidence: [String: Any] = ["operation": "track.strip_silence", "write_attempted": false]
        func refuse(_ error: HonestContract.FailureError, _ reason: String, _ hint: String) -> ChannelResult {
            evidence["reason"] = reason
            return .error(HonestContract.encodeStateC(error: error, hint: hint, extras: evidence))
        }
        guard let index = params["index"].flatMap(Int.init), index >= 0 else {
            return refuse(.invalidParams, "index_invalid", "strip_silence requires 'index' (Int ≥ 0)")
        }
        guard case .valid(let settings) = StripSilenceSettings.validated(
            threshold: params["threshold_db"].flatMap(Double.init),
            minimum: params["min_silence_sec"].flatMap(Double.init),
            preAttack: params["pre_attack_sec"].flatMap(Double.init),
            postRelease: params["post_release_sec"].flatMap(Double.init)
        ) else {
            return refuse(.invalidParams, "settings_out_of_range", "strip_silence settings are outside the dialog's ranges")
        }
        guard let header = AXLogicProElements.findTrackHeader(at: index, runtime: runtime) else {
            return refuse(.elementNotFound, "track_not_found", "Track at index \(index) not found")
        }
        let liveName = AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax).name
        evidence["track"] = index
        evidence["track_name"] = liveName
        if let expected = params["expected_name"], !expected.utf8.elementsEqual(liveName.utf8) {
            return refuse(.targetIdentityMismatch, "name_mismatch", "Track \(index) is '\(liveName)', not '\(expected)'.")
        }
        let front = FrontmostGate.prepareObserved(
            observe: runtime.observeFrontmost,
            activate: { ProcessUtils.activateLogicPro() },
            sleepMicros: { usleep($0) }
        )
        guard front.preparation.isReady else {
            return refuse(.unsupportedState, "logic_not_frontmost", "Logic Pro could not be brought to the front; nothing was changed.")
        }

        // 1. Exactly the track's audio regions selected.
        let before: [(item: AXUIElement, info: RegionInfo)]
        switch selectOnlyTrackRegions(index, kind: "audio", runtime: runtime) {
        case .selected(let selected):
            before = selected
        case .refused(let error, let reason, let hint, let more):
            evidence.merge(more) { _, new in new }
            return refuse(error, reason, hint + " Nothing was changed.")
        }
        evidence["regions_before"] = before.count

        // 2. Functions > Remove Silence from Audio Region…
        let windowsBefore = trackColorWindows(runtime: runtime)
        guard let functions = stripSilenceFunctionsButton(anchor: header, runtime: runtime) else {
            return refuse(.elementNotFound, "functions_menu_not_found", "The Tracks area's Functions menu button was not found; nothing was changed.")
        }
        _ = AXHelpers.performAction(functions, kAXPressAction as String, runtime: runtime.ax)
        var item: AXUIElement?
        for _ in 0..<10 {
            usleep(100_000)
            let matches = AXHelpers.findAllDescendants(of: functions, role: kAXMenuItemRole as String, maxDepth: 4, runtime: runtime.ax)
                .filter { AXLocalePolicy.removeSilenceMenuItem.matches(AXHelpers.getTitle($0, runtime: runtime.ax)) }
            if matches.count == 1 { item = matches[0]; break }
        }
        guard let item, (AXHelpers.getAttribute(item, kAXEnabledAttribute as String, runtime: runtime.ax) as Bool?) == true else {
            AXMouseHelper.pressEscape()
            return refuse(.elementNotFound, "menu_item_unavailable", "Remove Silence from Audio Region… was not found or not enabled; nothing was changed.")
        }
        _ = AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax)

        // 3. The dialog, by structure.
        var dialog: (window: AXUIElement, fields: [AXUIElement])?
        for _ in 0..<20 {
            usleep(100_000)
            dialog = stripSilenceDialog(excluding: windowsBefore, runtime: runtime)
            if dialog != nil { break }
        }
        guard let dialog else {
            return refuse(.dialogNotFound, "dialog_not_observed", "The Remove Silence window did not appear; nothing was changed.")
        }
        let window = dialog.window
        guard let ok: AXUIElement = AXHelpers.getAttribute(window, kAXDefaultButtonAttribute as String, runtime: runtime.ax),
              let cancel: AXUIElement = AXHelpers.getAttribute(window, kAXCancelButtonAttribute as String, runtime: runtime.ax) else {
            AXMouseHelper.pressEscape()
            return refuse(.unsupportedState, "dialog_layout_unrecognized", "The Remove Silence window has no default and cancel button; it was closed.")
        }
        func cancelDialog(_ error: HonestContract.FailureError, _ reason: String, _ hint: String) -> ChannelResult {
            _ = AXHelpers.performAction(cancel, kAXPressAction as String, runtime: runtime.ax)
            return refuse(error, reason, hint + " The dialog was cancelled; nothing was changed.")
        }

        // 4. Each field: double-click selects it, type, Tab commits; read it back.
        var applied: [String: Any] = [:]
        for field in StripSilenceSettings.Field.allCases {
            let group = dialog.fields[field.rawValue]
            guard let frame = stripSilenceFrame(group, runtime: runtime) else {
                return cancelDialog(.readbackUnavailable, "field_unreadable", "The \(field.parameter) field did not read.")
            }
            let shown = (AXHelpers.getValue(group, runtime: runtime.ax) as? String) ?? ""
            let text = StripSilenceSettings.typed(settings.value(field), field: field,
                                                  decimalMark: StripSilenceSettings.decimalMark(of: shown))
            var committed: String?
            for _ in 0..<2 where committed == nil {
                AXMouseHelper.doubleClick(at: CGPoint(x: frame.midX, y: frame.midY))
                usleep(150_000)
                AXMouseHelper.typeText(text)
                AXMouseHelper.pressTab()
                usleep(250_000)
                let after = (AXHelpers.getValue(group, runtime: runtime.ax) as? String) ?? ""
                if StripSilenceSettings.agrees(after, settings.value(field), field: field) { committed = after }
            }
            guard let committed else {
                return cancelDialog(.axWriteFailed, "field_not_set", "The \(field.parameter) field did not read back \(text).")
            }
            applied[field.parameter] = committed
        }
        evidence["applied_settings"] = applied

        // 5. The preview, then OK.
        let preview = AXHelpers.getChildren(window, runtime: runtime.ax)
            .filter { AXHelpers.getRole($0, runtime: runtime.ax) == kAXStaticTextRole as String }
            .compactMap { (AXHelpers.getValue($0, runtime: runtime.ax) as? String).flatMap(StripSilenceSettings.previewCount) }
        guard preview.count == 1, let expected = preview.first else {
            return cancelDialog(.readbackUnavailable, "preview_unreadable", "The dialog's region-count preview did not read as one number.")
        }
        evidence["preview_regions"] = expected
        _ = AXHelpers.performAction(ok, kAXPressAction as String, runtime: runtime.ax)
        evidence["write_attempted"] = true

        // 6. Read back: the track holds exactly the previewed number of audio regions.
        var after: Int?
        for _ in 0..<20 {
            usleep(150_000)
            if trackColorWindows(runtime: runtime).contains(where: { CFEqual($0, window) }) { continue }
            guard case .success(let arrangement) = enumerateRegionItems(runtime: runtime),
                  arrangement.regionItemsOutsideViewport == 0 else { continue }
            after = arrangement.regions.filter { $0.info.trackIndex == index && $0.info.kind == "audio" }.count
            if after == expected { break }
        }
        evidence["regions_after"] = after ?? NSNull()
        let witness = readStripSilenceUndoWitness(runtime: runtime)
        evidence["undo_title"] = witness ?? NSNull()
        guard after == expected else {
            evidence["hint"] = "OK was pressed; the track does not hold the previewed number of audio regions. Re-read the regions."
            return .success(HonestContract.encodeStateB(reason: after == nil ? .readbackUnavailable : .readbackMismatch, extras: evidence))
        }
        return .success(HonestContract.encodeStateA(extras: evidence))
    }

    /// The Tracks area's Functions button: the second from the left of the menu buttons in the row
    /// nearest above the track list (Edit, Functions, View, then tool menus; measured on 12.4).
    private static func stripSilenceFunctionsButton(anchor header: AXUIElement, runtime: AXLogicProElements.Runtime) -> AXUIElement? {
        let row = tracksAreaMenuRow(anchor: header, runtime: runtime)
        return row.count >= 3 ? row[1] : nil
    }

    /// The Tracks area's own menu buttons (measured on 12.4: Edit, Functions, View), left to right:
    /// the row of menu buttons nearest above the track list.
    static func tracksAreaMenuRow(anchor header: AXUIElement, runtime: AXLogicProElements.Runtime) -> [AXUIElement] {
        // The menu row sits above the track LIST, not above the target track: anchor on the
        // list's scroll area (measured: on a 21-track session, Voc at row 11 sat far below it).
        var ancestor: AXUIElement? = AXHelpers.getAttribute(header, kAXParentAttribute as String, runtime: runtime.ax)
        while let current = ancestor, AXHelpers.getRole(current, runtime: runtime.ax) != kAXScrollAreaRole as String {
            ancestor = AXHelpers.getAttribute(current, kAXParentAttribute as String, runtime: runtime.ax)
        }
        guard let window = AXLogicProElements.mainWindow(runtime: runtime),
              let top = AXHelpers.getPosition(ancestor ?? header, runtime: runtime.ax)?.y else { return [] }
        let buttons = AXHelpers.findAllDescendants(of: window, role: kAXMenuButtonRole as String, maxDepth: 14, runtime: runtime.ax)
            .compactMap { button -> (AXUIElement, CGPoint)? in AXHelpers.getPosition(button, runtime: runtime.ax).map { (button, $0) } }
            .filter { $0.1.y < top && top - $0.1.y < 160 }
        guard let rowY = buttons.map(\.1.y).max() else { return [] }
        return buttons.filter { abs($0.1.y - rowY) < 1 }.sorted { $0.1.x < $1.1.x }.map(\.0)
    }

    /// A new window holding four field groups (each a group of sliders), sorted top to bottom.
    private static func stripSilenceDialog(
        excluding before: [AXUIElement],
        runtime: AXLogicProElements.Runtime
    ) -> (window: AXUIElement, fields: [AXUIElement])? {
        let fresh = trackColorWindows(runtime: runtime).filter { window in !before.contains(where: { CFEqual($0, window) }) }
        for window in fresh {
            let fields = AXHelpers.getChildren(window, runtime: runtime.ax).filter { child in
                AXHelpers.getRole(child, runtime: runtime.ax) == kAXGroupRole as String
                    && AXHelpers.getChildren(child, runtime: runtime.ax).contains { AXHelpers.getRole($0, runtime: runtime.ax) == kAXSliderRole as String }
            }
            guard fields.count == StripSilenceSettings.Field.allCases.count else { continue }
            let sorted = fields.sorted { (AXHelpers.getPosition($0, runtime: runtime.ax)?.y ?? 0) < (AXHelpers.getPosition($1, runtime: runtime.ax)?.y ?? 0) }
            return (window, sorted)
        }
        return nil
    }

    private static func stripSilenceFrame(_ element: AXUIElement, runtime: AXLogicProElements.Runtime) -> CGRect? {
        guard let origin = AXHelpers.getPosition(element, runtime: runtime.ax),
              let size = AXHelpers.getSize(element, runtime: runtime.ax) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// The Edit menu's Undo title when it names a strip-silence operation; nil otherwise.
    private static func readStripSilenceUndoWitness(runtime: AXLogicProElements.Runtime) -> String? {
        guard case .found(let bar) = AXLogicProElements.menuItemRead(labelPath: [AXLocalePolicy.editUndoMenuPath.bar], runtime: runtime) else {
            return nil
        }
        _ = AXHelpers.performAction(bar, kAXPressAction as String, runtime: runtime.ax)
        usleep(120_000)
        defer { AXMouseHelper.pressEscape() }
        guard let item = AXLocalePolicy.findMenuItem(under: bar, matching: AXLocalePolicy.editUndoMenuPath.item,
                                                      mode: AXLocalePolicy.editUndoMenuPath.itemMode, runtime: runtime.ax),
              let title: String = AXHelpers.getAttribute(item, kAXTitleAttribute as String, runtime: runtime.ax),
              AXLocalePolicy.stripSilenceUndoOperation.containsAny(in: title) else { return nil }
        return title
    }
}
