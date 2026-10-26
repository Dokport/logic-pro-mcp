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
        /// The Undo entry names a region colour change.
        case changeRegionColor = "change_region_color"
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

        // 4-6. Open the palette through its own menu item and click the swatch.
        switch clickPaletteSwatch(
            menuPath: AXLocalePolicy.assignTrackColorMenuPath,
            menuName: "Assign Track Color…",
            row: row, column: column, operation: "track.set_color",
            evidence: &evidence, runtime: runtime
        ) {
        case .refused(let refusal):
            return refusal
        case .clicked:
            break
        }

        // 7. Read the witness (the palette is already closed).
        let witness = readTrackColorUndoWitness(runtime: runtime)
        evidence["undo_witness"] = witness.witness.rawValue
        evidence["undo_title"] = witness.title ?? NSNull()
        evidence["readback"] = "unavailable_via_ax"
        evidence["hint"] = "Track colour is not readable through Accessibility. Pass readback:\"project_file\" (saves the project) for a verified read."
        return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: evidence))
    }

    enum PaletteClick {
        /// Nothing was clicked; the reply is the State C refusal to return.
        case refused(ChannelResult)
        /// One click was posted on the swatch and the palette was closed again (`palette_closed`
        /// in the evidence says whether that worked).
        case clicked
    }

    /// Opens the colour palette through `menuPath`, derives the swatch's click point from the
    /// palette's own children, clicks it once with Logic frontmost, and closes the palette.
    /// Every refusal happens before the click and carries `write_attempted: false`.
    static func clickPaletteSwatch(
        menuPath: AXLocalePolicy.MenuPath,
        menuName: String,
        row: Int,
        column: Int,
        operation: String,
        evidence: inout [String: Any],
        runtime: AXLogicProElements.Runtime
    ) -> PaletteClick {
        func refuse(_ error: HonestContract.FailureError, _ reason: String, _ hint: String) -> PaletteClick {
            .refused(colorStateC(error, operation: operation, reason: reason, hint: hint, extras: evidence))
        }
        let windowsBefore = trackColorWindows(runtime: runtime)
        if windowsBefore.contains(where: { trackColorSwatchPositions(in: $0, runtime: runtime) != nil }) {
            return refuse(.unsupportedState, "palette_already_open",
                "A colour palette is already open; close it and retry. Nothing was clicked.")
        }
        let item: AXUIElement
        switch AXLogicProElements.menuItemRead(labelPath: [menuPath.bar, menuPath.item], runtime: runtime) {
        case .found(let found):
            item = found
        case .absent:
            return refuse(.elementNotFound, "menu_item_absent", "\(menuName) was not found in this Logic's menu bar.")
        case .unreadable(let stage, let status):
            evidence["read_failure_stage"] = stage
            evidence["read_failure_status"] = status
            return refuse(.readbackUnavailable, "menu_unreadable", "The menu holding \(menuName) could not be read; nothing was pressed.")
        }
        guard AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax)
            || trackColorPalette(runtime: runtime, excluding: windowsBefore) != nil else {
            return refuse(.axWriteFailed, "menu_press_failed", "\(menuName) did not open the palette.")
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
            return refuse(.windowOpenFailed, "palette_not_observed",
                "The colour palette did not appear after \(menuName); nothing was clicked.")
        }
        let point: CGPoint
        switch TrackColorPaletteGeometry.clickPoint(row: row, column: column, childPositions: palette.positions) {
        case .point(let derived):
            point = derived
        case .layoutUnrecognized(let why):
            evidence["palette_layout"] = why
            evidence["palette_closed"] = closeTrackColorPalette(palette.window, runtime: runtime)
            return refuse(.unsupportedState, "palette_layout_unrecognized",
                "The colour palette's layout is not the one measured on Logic \(TrackColorPalette.measuredLogicVersion) (\(why)); nothing was clicked.")
        }
        if let frame = trackColorFrame(palette.window, runtime: runtime), !frame.contains(point) {
            evidence["palette_closed"] = closeTrackColorPalette(palette.window, runtime: runtime)
            return refuse(.unsupportedState, "click_point_outside_palette",
                "The derived swatch position lies outside the palette window; nothing was clicked.")
        }
        let refront = FrontmostGate.prepareObserved(
            observe: runtime.observeFrontmost,
            activate: { ProcessUtils.activateLogicPro() },
            sleepMicros: { usleep($0) }
        )
        guard refront.preparation.isReady else {
            evidence["palette_closed"] = closeTrackColorPalette(palette.window, runtime: runtime)
            return refuse(.unsupportedState, "logic_not_frontmost",
                "Logic Pro lost the front before the swatch click; nothing was clicked.")
        }
        // From here on the colour may have changed: nothing after this is a State C refusal.
        evidence["click_posted"] = AXMouseHelper.click(at: point)
        evidence["write_attempted"] = true
        evidence["write_channel"] = "cgevent_click_on_ax_derived_swatch"
        usleep(trackColorSettleMicros)
        evidence["palette_closed"] = closeTrackColorPalette(palette.window, runtime: runtime)
        return .clicked
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
        colorStateC(error, operation: "track.set_color", reason: reason, hint: hint, extras: extras)
    }

    private static func colorStateC(
        _ error: HonestContract.FailureError,
        operation: String,
        reason: String,
        hint: String,
        extras: [String: Any] = [:]
    ) -> ChannelResult {
        var details = extras
        details["operation"] = operation
        details["reason"] = reason
        details["write_attempted"] = false
        return .error(HonestContract.encodeStateC(error: error, hint: hint, extras: details))
    }

    static func trackColorWindows(runtime: AXLogicProElements.Runtime) -> [AXUIElement] {
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
        if AXLocalePolicy.changeRegionColorUndoOperation.containsAny(in: title) { return (.changeRegionColor, title) }
        if AXLocalePolicy.changeTrackColorUndoOperation.containsAny(in: title) { return (.changeTrackColor, title) }
        return (.otherOperation, title)
    }


    enum TrackRegionSelection {
        case selected([(item: AXUIElement, info: RegionInfo)])
        case refused(HonestContract.FailureError, reason: String, hint: String, extras: [String: Any])
    }

    /// Edit > Deselect All, then `AXSelected` on every region the arrangement shows on track
    /// `index` (optionally only those of `kind`), and the whole selected set read back as exactly
    /// those regions. Regions outside the visible arrangement refuse: "all regions of this track"
    /// could not be established. Shared by region colouring and strip silence.
    static func selectOnlyTrackRegions(
        _ index: Int,
        kind: String? = nil,
        runtime: AXLogicProElements.Runtime
    ) -> TrackRegionSelection {
        guard case .success(let arrangement) = enumerateRegionItems(runtime: runtime) else {
            return .refused(.readbackUnavailable, reason: "regions_unreadable",
                hint: "The arrangement's regions could not be read.", extras: [:])
        }
        guard arrangement.regionItemsOutsideViewport == 0 else {
            return .refused(.unsupportedState, reason: "regions_outside_viewport",
                hint: "Some regions lie outside the visible arrangement, so 'all regions of this track' cannot be established. Zoom to fit and retry.",
                extras: ["region_items_outside_viewport": arrangement.regionItemsOutsideViewport])
        }
        let targets = arrangement.regions.filter { $0.info.trackIndex == index && (kind == nil || $0.info.kind == kind) }
        guard !targets.isEmpty else {
            return .refused(.elementNotFound, reason: "no_regions",
                hint: "Track \(index) shows no\(kind.map { " \($0)" } ?? "") regions.", extras: [:])
        }
        if let deselect = AXLogicProElements.menuItem(identifier: "deselectAll:", inMenuBar: AXLocalePolicy.editMenuBar, runtime: runtime) {
            _ = AXHelpers.performAction(deselect, kAXPressAction as String, runtime: runtime.ax)
        }
        usleep(150_000)
        guard let cleared = selectedRegionInfos(runtime: runtime), cleared.isEmpty else {
            return .refused(.unsupportedState, reason: "selection_not_cleared",
                hint: "Edit > Deselect All did not leave an empty, readable region selection.", extras: [:])
        }
        for target in targets {
            _ = AXHelpers.setAttribute(target.item, kAXSelectedAttribute, kCFBooleanTrue, runtime: runtime.ax)
        }
        usleep(150_000)
        func key(_ info: RegionInfo) -> String { "\(info.trackIndex)|\(info.startBar)|\(info.endBar)|\(info.name)" }
        guard let selected = selectedRegionInfos(runtime: runtime),
              selected.map(key).sorted() == targets.map({ key($0.info) }).sorted() else {
            return .refused(.unsupportedState, reason: "selection_not_exact",
                hint: "The region selection did not read back as exactly track \(index)'s regions.", extras: [:])
        }
        return .selected(targets)
    }

    // MARK: - region.set_color

    /// `region.set_color`: select exactly the regions of one track, open View > Colors with the
    /// arrangement area focused, click one swatch.
    ///
    /// The regions are selected through their own `AXSelected` after Edit > Deselect All, the same
    /// write `region.select_last` measured, and the whole selected set must read back as exactly
    /// those regions before anything is clicked. A region colour, like a track colour, has no AX
    /// readback; the Undo title separates the two (`Change Region Color` vs `Change Track Color`),
    /// so the witness also says which of the two the click changed.
    static func defaultSetRegionColor(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        func refuse(_ error: HonestContract.FailureError, _ reason: String, _ hint: String, _ extras: [String: Any]) -> ChannelResult {
            colorStateC(error, operation: "region.set_color", reason: reason, hint: hint, extras: extras)
        }
        guard let indexRaw = params["index"], let index = Int(indexRaw), index >= 0 else {
            return refuse(.invalidParams, "index_invalid", "region set_color requires the track 'index' (Int ≥ 0)", [:])
        }
        guard let row = params["row"].flatMap(Int.init), let column = params["column"].flatMap(Int.init),
              let swatch = TrackColorPalette.swatch(row: row, column: column) else {
            return refuse(.invalidParams, "swatch_invalid", "region set_color requires a palette row (1-4) and column (1-24)", [:])
        }
        var evidence: [String: Any] = [
            "track": index,
            "requested_color": trackColorDescription(swatch),
            "palette_measured_on": "Logic Pro \(TrackColorPalette.measuredLogicVersion)",
        ]
        guard let header = AXLogicProElements.findTrackHeader(at: index, runtime: runtime) else {
            return refuse(.elementNotFound, "track_not_found", "Track at index \(index) not found", evidence)
        }
        let liveName = AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax).name
        evidence["track_name"] = liveName
        if let expected = params["expected_name"], !expected.utf8.elementsEqual(liveName.utf8) {
            evidence["expected_name"] = expected
            return refuse(.targetIdentityMismatch, "name_mismatch",
                "Track \(index) is '\(liveName)', not '\(expected)'. Re-read logic://tracks.", evidence)
        }
        let front = FrontmostGate.prepareObserved(
            observe: runtime.observeFrontmost,
            activate: { ProcessUtils.activateLogicPro() },
            sleepMicros: { usleep($0) }
        )
        evidence["frontmost_preparation"] = front.preparation.rawValue
        guard front.preparation.isReady else {
            return refuse(.unsupportedState, "logic_not_frontmost", "Logic Pro could not be brought to the front; nothing was clicked.", evidence)
        }

        let targets: [(item: AXUIElement, info: RegionInfo)]
        switch selectOnlyTrackRegions(index, runtime: runtime) {
        case .selected(let selected):
            targets = selected
            evidence["region_count"] = selected.count
        case .refused(let error, let reason, let hint, let more):
            evidence.merge(more) { _, new in new }
            return refuse(error, reason, hint + " Nothing was coloured.", evidence)
        }

        // The palette colours what has key focus: give it to the arrangement, at the first region.
        _ = AXHelpers.setAttribute(targets[0].item, kAXFocusedAttribute, kCFBooleanTrue, runtime: runtime.ax)
        switch clickPaletteSwatch(
            menuPath: AXLocalePolicy.viewColorsMenuPath,
            menuName: "View > Colors",
            row: row, column: column, operation: "region.set_color",
            evidence: &evidence, runtime: runtime
        ) {
        case .refused(let refusal):
            return refusal
        case .clicked:
            break
        }
        let witness = readTrackColorUndoWitness(runtime: runtime)
        evidence["undo_witness"] = witness.witness.rawValue
        evidence["undo_title"] = witness.title ?? NSNull()
        evidence["readback"] = "unavailable_via_ax"
        if witness.witness == .changeTrackColor {
            // The click landed on the track, not the regions. Said plainly, not hidden in a B.
            evidence["hint"] = "The palette changed the TRACK colour instead of the regions' colour."
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: evidence))
        }
        evidence["hint"] = "Region colour is not readable through Accessibility; the Undo title names the change."
        return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: evidence))
    }
}
