import ApplicationServices
import Foundation

/// `track.set_color`: select one track, open Track > Assign Track Color…, click one swatch.
///
/// Why this is the shape it is (measured on Logic 12.4, `research/FINDINGS.md`):
///
/// - There is no AX write. The palette's swatches advertise `AXPress` and answer it with
///   success, and nothing changes: `ProjectData` is byte-identical after a save. A native click
///   at the swatch changes the colour. The click point is derived from the palette's own AX
///   children by `TrackColorPaletteGeometry`, which refuses a layout it does not recognise; no
///   coordinate is typed anywhere.
/// - There is no AX read. Nothing in Logic's tree carries a colour (#448). The click is never
///   treated as evidence: this channel answers State B at best, carrying the Edit menu's Undo
///   title as a witness that A track colour changed. The dispatcher can upgrade that to State A
///   by saving and reading the track record in `ProjectData` (`TrackColorProjectFile`), which is
///   the independent readback ADR-001's coordinate rule asks for.
extension AccessibilityChannel {
    /// How long the palette is given to appear after the menu press, and how often it is looked for.
    private static let trackColorPalettePolls = 15
    private static let trackColorPalettePollMicros: UInt32 = 100_000
    /// After the click, before the palette is closed and the Undo title is read.
    private static let trackColorSettleMicros: UInt32 = 300_000

    enum TrackColorUndoWitness: String, Sendable {
        /// The Undo entry names a track colour change.
        case changeTrackColor = "change_track_color"
        /// The Undo entry read and names something else (or nothing can be undone).
        case otherOperation = "other_operation"
        /// The Edit menu or its Undo entry did not read.
        case unreadable
    }

    static func defaultSetTrackColor(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        guard let indexRaw = params["index"], let index = Int(indexRaw), index >= 0 else {
            return trackColorStateC(.invalidParams, reason: "index_invalid", hint: "set_color requires 'index' (Int ≥ 0)")
        }
        guard let rowRaw = params["row"], let row = Int(rowRaw),
              let columnRaw = params["column"], let column = Int(columnRaw),
              let swatch = TrackColorPalette.swatch(row: row, column: column) else {
            return trackColorStateC(.invalidParams, reason: "swatch_invalid", hint: "set_color requires a palette row (1-4) and column (1-24)")
        }
        var evidence: [String: Any] = [
            "track": index,
            "requested_color": trackColorDescription(swatch),
            "palette_measured_on": "Logic Pro \(TrackColorPalette.measuredLogicVersion)",
        ]

        // 1. The target, by its live header, never the cache.
        guard let header = AXLogicProElements.findTrackHeader(at: index, runtime: runtime) else {
            return trackColorStateC(.elementNotFound, reason: "track_not_found", hint: "Track at index \(index) not found", extras: evidence)
        }
        let liveName = AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax).name
        evidence["track_name"] = liveName
        if let expected = params["expected_name"], !expected.utf8.elementsEqual(liveName.utf8) {
            evidence["expected_name"] = expected
            return trackColorStateC(.targetIdentityMismatch, reason: "name_mismatch",
                hint: "Track \(index) is '\(liveName)', not '\(expected)'. Re-read logic://tracks.", extras: evidence)
        }

        // 2. Logic owns the keyboard and the window server, or nothing is touched.
        let front = FrontmostGate.prepareObserved(
            observe: runtime.observeFrontmost,
            activate: { ProcessUtils.activateLogicPro() },
            sleepMicros: { usleep($0) }
        )
        evidence["frontmost_preparation"] = front.preparation.rawValue
        guard front.preparation.isReady else {
            return trackColorStateC(.unsupportedState, reason: "logic_not_frontmost",
                hint: "Logic Pro could not be brought to the front; nothing was clicked.", extras: evidence)
        }

        // 3. Exactly this track selected: the palette colours the selection.
        guard AXLogicProElements.selectTrackViaAX(at: index, runtime: runtime) else {
            return trackColorStateC(.trackSelectionFailed, reason: "select_failed",
                hint: "Track \(index) could not be selected; no colour was changed.", extras: evidence)
        }
        let selection = await verifyTrackSelection(index: index, runtime: runtime)
        guard selection == .verified else {
            evidence["selection"] = "\(selection)"
            return trackColorStateC(.trackSelectionFailed, reason: "selection_not_exclusive",
                hint: "Track \(index) did not read as the only selected track; no colour was changed.", extras: evidence)
        }

        // 4. Open the palette through its own menu item.
        let windowsBefore = trackColorWindows(runtime: runtime)
        if windowsBefore.contains(where: { trackColorSwatchPositions(in: $0, runtime: runtime) != nil }) {
            return trackColorStateC(.unsupportedState, reason: "palette_already_open",
                hint: "A colour palette is already open; close it and retry. Nothing was clicked.", extras: evidence)
        }
        let item: AXUIElement
        switch AXLogicProElements.menuItemRead(
            labelPath: [AXLocalePolicy.assignTrackColorMenuPath.bar, AXLocalePolicy.assignTrackColorMenuPath.item],
            runtime: runtime
        ) {
        case .found(let found):
            item = found
        case .absent:
            return trackColorStateC(.elementNotFound, reason: "menu_item_absent",
                hint: "Track > Assign Track Color… was not found in this Logic's menu bar.", extras: evidence)
        case .unreadable(let stage, let status):
            evidence["read_failure_stage"] = stage
            evidence["read_failure_status"] = status
            return trackColorStateC(.readbackUnavailable, reason: "menu_unreadable",
                hint: "The Track menu could not be read; nothing was pressed.", extras: evidence)
        }
        guard AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax)
            || trackColorPalette(runtime: runtime, excluding: windowsBefore) != nil else {
            return trackColorStateC(.axWriteFailed, reason: "menu_press_failed",
                hint: "Assign Track Color… did not open the palette.", extras: evidence)
        }
        var palette: (window: AXUIElement, positions: [CGPoint])?
        for _ in 0..<trackColorPalettePolls {
            if let found = trackColorPalette(runtime: runtime, excluding: windowsBefore) {
                palette = found
                break
            }
            usleep(trackColorPalettePollMicros)
        }
        guard let palette else {
            return trackColorStateC(.windowOpenFailed, reason: "palette_not_observed",
                hint: "The colour palette did not appear after Assign Track Color…; nothing was clicked.", extras: evidence)
        }

        // 5. Where to click, from the palette's own children.
        let point: CGPoint
        switch TrackColorPaletteGeometry.clickPoint(row: row, column: column, childPositions: palette.positions) {
        case .point(let derived):
            point = derived
        case .layoutUnrecognized(let why):
            let closed = closeTrackColorPalette(palette.window, runtime: runtime)
            evidence["palette_layout"] = why
            evidence["palette_closed"] = closed
            return trackColorStateC(.unsupportedState, reason: "palette_layout_unrecognized",
                hint: "The colour palette's layout is not the one measured on Logic \(TrackColorPalette.measuredLogicVersion) (\(why)); nothing was clicked.",
                extras: evidence)
        }
        if let frame = trackColorFrame(palette.window, runtime: runtime), !frame.contains(point) {
            let closed = closeTrackColorPalette(palette.window, runtime: runtime)
            evidence["palette_closed"] = closed
            return trackColorStateC(.unsupportedState, reason: "click_point_outside_palette",
                hint: "The derived swatch position lies outside the palette window; nothing was clicked.", extras: evidence)
        }

        // 6. Click. From here on the colour may have changed, so nothing below is State C.
        let refront = FrontmostGate.prepareObserved(
            observe: runtime.observeFrontmost,
            activate: { ProcessUtils.activateLogicPro() },
            sleepMicros: { usleep($0) }
        )
        guard refront.preparation.isReady else {
            let closed = closeTrackColorPalette(palette.window, runtime: runtime)
            evidence["palette_closed"] = closed
            return trackColorStateC(.unsupportedState, reason: "logic_not_frontmost",
                hint: "Logic Pro lost the front before the swatch click; nothing was clicked.", extras: evidence)
        }
        let posted = AXMouseHelper.click(at: point)
        evidence["write_attempted"] = true
        evidence["click_posted"] = posted
        evidence["write_channel"] = "cgevent_click_on_ax_derived_swatch"
        usleep(trackColorSettleMicros)

        // 7. Put the UI back, then read the witness.
        evidence["palette_closed"] = closeTrackColorPalette(palette.window, runtime: runtime)
        let witness = readTrackColorUndoWitness(runtime: runtime)
        evidence["undo_witness"] = witness.witness.rawValue
        evidence["undo_title"] = witness.title ?? NSNull()
        evidence["readback"] = "unavailable_via_ax"
        evidence["hint"] = "Track colour is not readable through Accessibility. Pass readback:\"project_file\" (saves the project) for a verified read."
        return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: evidence))
    }

    static func trackColorDescription(_ swatch: TrackColorSwatch) -> [String: Any] {
        ["row": swatch.row, "column": swatch.column, "stored_index": swatch.storedIndex, "rgb": swatch.rgb]
    }

    private static func trackColorStateC(
        _ error: HonestContract.FailureError,
        reason: String,
        hint: String,
        extras: [String: Any] = [:]
    ) -> ChannelResult {
        var details = extras
        details["operation"] = "track.set_color"
        details["reason"] = reason
        details["write_attempted"] = false
        return .error(HonestContract.encodeStateC(error: error, hint: hint, extras: details))
    }

    private static func trackColorWindows(runtime: AXLogicProElements.Runtime) -> [AXUIElement] {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return [] }
        return AXHelpers.getAttribute(app, kAXWindowsAttribute as String, runtime: runtime.ax) ?? []
    }

    /// A newly appeared window whose content is the palette's swatch group.
    private static func trackColorPalette(
        runtime: AXLogicProElements.Runtime,
        excluding before: [AXUIElement]
    ) -> (window: AXUIElement, positions: [CGPoint])? {
        let fresh = trackColorWindows(runtime: runtime).filter { window in
            !before.contains(where: { CFEqual($0, window) })
        }
        let palettes = fresh.compactMap { window -> (AXUIElement, [CGPoint])? in
            trackColorSwatchPositions(in: window, runtime: runtime).map { (window, $0) }
        }
        return palettes.count == 1 ? palettes[0] : nil
    }

    /// The palette is a window holding one group holding one group of exactly 97 children whose
    /// only readable attribute is a position. Matched by that structure, not by its localized title.
    private static func trackColorSwatchPositions(
        in window: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) -> [CGPoint]? {
        for outer in AXHelpers.getChildren(window, runtime: runtime.ax)
            where AXHelpers.getRole(outer, runtime: runtime.ax) == kAXGroupRole as String {
            for inner in AXHelpers.getChildren(outer, runtime: runtime.ax)
                where AXHelpers.getRole(inner, runtime: runtime.ax) == kAXGroupRole as String {
                let swatches = AXHelpers.getChildren(inner, runtime: runtime.ax)
                guard swatches.count == TrackColorPaletteGeometry.expectedChildCount else { continue }
                let positions = swatches.compactMap { AXHelpers.getPosition($0, runtime: runtime.ax) }
                guard positions.count == swatches.count,
                      swatches.allSatisfy({ AXHelpers.getRole($0, runtime: runtime.ax) == nil }) else { continue }
                return positions
            }
        }
        return nil
    }

    private static func trackColorFrame(_ window: AXUIElement, runtime: AXLogicProElements.Runtime) -> CGRect? {
        guard let origin = AXHelpers.getPosition(window, runtime: runtime.ax),
              let size = AXHelpers.getSize(window, runtime: runtime.ax) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Presses the palette's own close button and reports whether the window is gone.
    ///
    /// Measured on 12.4: the palette answers `AXCloseButton` with no value; its close control is
    /// its only direct `AXButton` child (described `close`, no subrole). Exactly one is required.
    private static func closeTrackColorPalette(_ window: AXUIElement, runtime: AXLogicProElements.Runtime) -> Bool {
        let buttons = AXHelpers.getChildren(window, runtime: runtime.ax)
            .filter { AXHelpers.getRole($0, runtime: runtime.ax) == kAXButtonRole as String }
        if buttons.count == 1 {
            _ = AXHelpers.performAction(buttons[0], kAXPressAction as String, runtime: runtime.ax)
        }
        for _ in 0..<10 {
            if !trackColorWindows(runtime: runtime).contains(where: { CFEqual($0, window) }) { return true }
            usleep(50_000)
        }
        return false
    }

    /// Opens the Edit menu, reads its Undo entry's title, closes the menu.
    static func readTrackColorUndoWitness(
        runtime: AXLogicProElements.Runtime
    ) -> (witness: TrackColorUndoWitness, title: String?) {
        guard case .found(let bar) = AXLogicProElements.menuItemRead(
            labelPath: [AXLocalePolicy.editUndoMenuPath.bar], runtime: runtime
        ) else {
            return (.unreadable, nil)
        }
        _ = AXHelpers.performAction(bar, kAXPressAction as String, runtime: runtime.ax)
        usleep(120_000)
        defer { AXMouseHelper.pressEscape() }
        guard let item = AXLocalePolicy.findMenuItem(
            under: bar,
            matching: AXLocalePolicy.editUndoMenuPath.item,
            mode: AXLocalePolicy.editUndoMenuPath.itemMode,
            runtime: runtime.ax
        ) else {
            return (.otherOperation, nil)
        }
        let title: String? = AXHelpers.getAttribute(item, kAXTitleAttribute as String, runtime: runtime.ax)
        guard let title else { return (.unreadable, nil) }
        return (AXLocalePolicy.changeTrackColorUndoOperation.containsAny(in: title) ? .changeTrackColor : .otherOperation, title)
    }
}
