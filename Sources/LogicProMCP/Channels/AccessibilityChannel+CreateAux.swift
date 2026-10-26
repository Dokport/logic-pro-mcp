import ApplicationServices
import Foundation

/// `mixer.create_aux`: Mixer > Options > Create New Auxiliary Channel Strip, read back as exactly
/// one new strip.
///
/// Measured on Logic 12.4 (`research/ax/mixer-Options-menu.txt`): the Mixer's local menus are
/// `AXMenuButton`s whose descriptions have no unique row in Logic's strings, so the item is found
/// by its own (derived) label inside whichever of those menus holds it. An aux that no track uses
/// may not be shown in the Mixer's Tracks view, so the strip census is taken in the All view and
/// the view the user had is put back afterwards.
extension AccessibilityChannel {
    static func defaultCreateAux(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        func refuse(_ error: HonestContract.FailureError, _ reason: String, _ hint: String, _ extras: [String: Any] = [:]) -> ChannelResult {
            var details = extras
            details["operation"] = "mixer.create_aux"
            details["reason"] = reason
            details["write_attempted"] = false
            return .error(HonestContract.encodeStateC(error: error, hint: hint, extras: details))
        }
        var evidence: [String: Any] = [:]
        guard let mixer = AXLogicProElements.getMixerArea(runtime: runtime) else {
            return refuse(.elementNotFound, "mixer_not_visible", "The Mixer is not shown; open it (View > Mixer) and retry.")
        }
        let front = FrontmostGate.prepareObserved(
            observe: runtime.observeFrontmost,
            activate: { ProcessUtils.activateLogicPro() },
            sleepMicros: { usleep($0) }
        )
        guard front.preparation.isReady else {
            return refuse(.unsupportedState, "logic_not_frontmost", "Logic Pro could not be brought to the front; nothing was pressed.")
        }
        let toolbar: AXUIElement = AXHelpers.getAttribute(mixer, kAXParentAttribute as String, runtime: runtime.ax) ?? mixer

        // Census in the All view; remember the view to restore.
        let viewModes = createAuxViewModeButtons(in: toolbar, runtime: runtime)
        let originalMode = viewModes?.firstIndex { (AXHelpers.getValue($0, runtime: runtime.ax) as? NSNumber)?.intValue == 1 }
        if let viewModes, originalMode != 2 {
            _ = AXHelpers.performAction(viewModes[2], kAXPressAction as String, runtime: runtime.ax)
            usleep(250_000)
        }
        func restoreView() {
            if let viewModes, let originalMode, originalMode != 2 {
                _ = AXHelpers.performAction(viewModes[originalMode], kAXPressAction as String, runtime: runtime.ax)
                evidence["view_restored"] = true
            }
        }
        evidence["view_mode_switched"] = viewModes != nil && originalMode != 2
        guard let currentMixer = AXLogicProElements.getMixerArea(runtime: runtime),
              let before = createAuxStripNames(in: currentMixer, runtime: runtime) else {
            restoreView()
            return refuse(.readbackUnavailable, "strips_unreadable", "The Mixer's strips did not read completely; nothing was pressed.", evidence)
        }
        evidence["strips_before"] = before

        let pressed: MixerOptionsPress = pressMixerOptionsItem(
            AXLocalePolicy.mixerCreateAuxiliaryChannelStrip, mixer: currentMixer, evidence: &evidence, runtime: runtime)
        if case .disabled = pressed {
            restoreView()
            return refuse(.unsupportedState, "menu_item_disabled", "Create New Auxiliary Channel Strip is not enabled.", evidence)
        }
        guard case .pressed = pressed else {
            restoreView()
            return refuse(.elementNotFound, "menu_item_absent", "No Mixer menu offers Create New Auxiliary Channel Strip.", evidence)
        }
        evidence["write_attempted"] = true

        // Exactly one new strip.
        var added: [String] = []
        var after: [String] = []
        for _ in 0..<15 {
            usleep(100_000)
            guard let mixerNow = AXLogicProElements.getMixerArea(runtime: runtime),
                  let names = createAuxStripNames(in: mixerNow, runtime: runtime) else { continue }
            after = names
            added = CreateAuxVerifier.added(before: before, after: names)
            if !added.isEmpty { break }
        }
        evidence["strips_after"] = after
        restoreView()
        switch CreateAuxVerifier.verdict(before: before, after: after) {
        case .created(let name, let position):
            evidence["aux_name"] = name
            evidence["aux_strip_index"] = position
            return .success(HonestContract.encodeStateA(extras: evidence))
        case .unchanged:
            evidence["detail"] = "no new strip appeared"
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: evidence))
        case .unexpected(let why):
            evidence["detail"] = why
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: evidence))
        }
    }

    enum MixerOptionsPress { case pressed, disabled, absent }

    /// Presses the item labelled `label` in the Mixer's Options menu.
    ///
    /// The Mixer's own menu buttons (measured on 12.4: Edit, Options, View) are the row of menu
    /// buttons nearest above the Mixer area, in a sibling group; Options is the second from the
    /// left. Only that one is pressed, and its item is still matched by label before anything is
    /// pressed in it: pressing other menus to look for it left Logic's menu tracking unsettled.
    static func pressMixerOptionsItem(
        _ label: AXLocalePolicy.LabelSet,
        mixer: AXUIElement,
        evidence: inout [String: Any],
        runtime: AXLogicProElements.Runtime
    ) -> MixerOptionsPress {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime) else { return .absent }
        let mixerTop = AXHelpers.getPosition(mixer, runtime: runtime.ax)?.y ?? 0
        let candidates = AXHelpers.findAllDescendants(of: window, role: kAXMenuButtonRole as String, maxDepth: 14, runtime: runtime.ax)
            .compactMap { button -> (button: AXUIElement, at: CGPoint)? in
                AXHelpers.getPosition(button, runtime: runtime.ax).map { (button, $0) }
            }
            .filter { $0.at.y < mixerTop && mixerTop - $0.at.y < 80 }
        let rowY = candidates.map(\.at.y).max()
        let row = candidates.filter { abs($0.at.y - (rowY ?? 0)) < 1 }.sorted { $0.at.x < $1.at.x }
        evidence["mixer_menu_buttons"] = row.count
        guard row.count == 3 else { return .absent }
        let options = row[1].button
        _ = AXHelpers.performAction(options, kAXPressAction as String, runtime: runtime.ax)
        var items: [AXUIElement] = []
        for _ in 0..<10 {
            usleep(100_000)
            items = AXHelpers.findAllDescendants(of: options, role: kAXMenuItemRole as String, maxDepth: 3, runtime: runtime.ax)
                .filter { label.matches(AXHelpers.getTitle($0, runtime: runtime.ax)) }
            if !items.isEmpty { break }
        }
        guard items.count == 1 else {
            AXMouseHelper.pressEscape()
            return .absent
        }
        let enabled: Bool? = AXHelpers.getAttribute(items[0], kAXEnabledAttribute as String, runtime: runtime.ax)
        guard enabled == true else {
            AXMouseHelper.pressEscape()
            return .disabled
        }
        _ = AXHelpers.performAction(items[0], kAXPressAction as String, runtime: runtime.ax)
        return .pressed
    }

    /// `mixer.create_track_for_strip`: select one Mixer strip by its exact name (a plain click on its
    /// name field), Options > Create Tracks for Selected Channel Strips, and read the track list
    /// back: exactly one new track carrying the strip's name, every other track unchanged in order.
    /// Measured on Logic 12.4: an aux created by a send becomes a track this way, so the track tools
    /// (rename, colour, plug-in insertion) reach it.
    static func defaultCreateTrackForStrip(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        var evidence: [String: Any] = ["operation": "mixer.create_track_for_strip", "write_attempted": false]
        func refuse(_ error: HonestContract.FailureError, _ reason: String, _ hint: String) -> ChannelResult {
            evidence["reason"] = reason
            return .error(HonestContract.encodeStateC(error: error, hint: hint, extras: evidence))
        }
        guard let stripName = params["strip"], !stripName.isEmpty else {
            return refuse(.invalidParams, "strip_missing", "create_track_for_strip requires 'strip': the Mixer strip's name")
        }
        evidence["strip"] = stripName
        guard let mixer = AXLogicProElements.getMixerArea(runtime: runtime),
              let strips = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: runtime.ax)?.strips else {
            return refuse(.elementNotFound, "mixer_not_visible", "The Mixer is not shown or its strips did not read; nothing was pressed.")
        }
        let matches = strips.filter { (AXHelpers.getDescription($0, runtime: runtime.ax) ?? "").utf8.elementsEqual(stripName.utf8) }
        guard matches.count == 1 else {
            return refuse(matches.isEmpty ? .elementNotFound : .ambiguousTargetName,
                          matches.isEmpty ? "strip_not_found" : "strip_ambiguous",
                          "Exactly one Mixer strip must be named '\(stripName)'; found \(matches.count).")
        }
        guard case .read(let before) = trackStackRailRead(runtime: runtime) else {
            return refuse(.readbackUnavailable, "rail_unreadable", "The track list did not read; nothing was pressed.")
        }
        let namesBefore = before.map(\.name)
        guard !namesBefore.contains(where: { $0.utf8.elementsEqual(stripName.utf8) }) else {
            return refuse(.unsupportedState, "track_exists", "A track named '\(stripName)' already exists; nothing was pressed.")
        }
        guard let field = AXHelpers.getChildren(matches[0], runtime: runtime.ax)
                .first(where: { AXHelpers.getRole($0, runtime: runtime.ax) == kAXTextFieldRole as String }),
              let origin = AXHelpers.getPosition(field, runtime: runtime.ax),
              let size = AXHelpers.getSize(field, runtime: runtime.ax) else {
            return refuse(.elementNotFound, "name_field_unreadable", "The strip's name field did not read; nothing was pressed.")
        }
        let front = FrontmostGate.prepareObserved(
            observe: runtime.observeFrontmost,
            activate: { ProcessUtils.activateLogicPro() },
            sleepMicros: { usleep($0) }
        )
        guard front.preparation.isReady else {
            return refuse(.unsupportedState, "logic_not_frontmost", "Logic Pro could not be brought to the front; nothing was pressed.")
        }
        // Measured: the first click on a strip that has just appeared is sometimes not taken as a
        // selection, and the menu item then reads disabled; one more click (outside the
        // double-click interval, which would start a rename) settles it.
        var pressed = false
        for attempt in 1...2 where !pressed {
            evidence["select_clicks"] = attempt
            AXMouseHelper.click(at: CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2))
            usleep(attempt == 1 ? 400_000 : 900_000)
            switch pressMixerOptionsItem(AXLocalePolicy.mixerAppendTracksForSelectedStrips, mixer: mixer, evidence: &evidence, runtime: runtime) {
            case .pressed:
                pressed = true
            case .disabled:
                if attempt == 2 {
                    return refuse(.unsupportedState, "menu_item_disabled",
                        "Create Tracks for Selected Channel Strips is not enabled: the strip did not become selected. Only the strip was clicked.")
                }
                usleep(300_000)
            case .absent:
                return refuse(.elementNotFound, "menu_item_absent", "The Mixer's Options menu does not offer Create Tracks for Selected Channel Strips.")
            }
        }
        evidence["write_attempted"] = true
        var after: [String] = []
        for _ in 0..<15 {
            usleep(100_000)
            guard case .read(let rows) = trackStackRailRead(runtime: runtime) else { continue }
            after = rows.map(\.name)
            if after.count == namesBefore.count + 1 { break }
        }
        evidence["after_order"] = after
        if case .created(let name, let position) = CreateAuxVerifier.verdict(before: namesBefore, after: after),
           name.utf8.elementsEqual(stripName.utf8) {
            evidence["track_index"] = position
            return .success(HonestContract.encodeStateA(extras: evidence))
        }
        evidence["hint"] = "The menu was pressed; the track list does not show exactly one new track named '\(stripName)'."
        return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: evidence))
    }

    /// The Single / Tracks / All radio group: the toolbar's only group of exactly three radios.
    private static func createAuxViewModeButtons(in toolbar: AXUIElement, runtime: AXLogicProElements.Runtime) -> [AXUIElement]? {
        let groups = AXHelpers.findAllDescendants(of: toolbar, role: kAXRadioGroupRole as String, maxDepth: 3, runtime: runtime.ax)
            .map { AXHelpers.getChildren($0, runtime: runtime.ax).filter { AXHelpers.getRole($0, runtime: runtime.ax) == kAXRadioButtonRole as String } }
            .filter { $0.count == 3 }
        return groups.count == 1 ? groups[0] : nil
    }

    private static func createAuxStripNames(in mixer: AXUIElement, runtime: AXLogicProElements.Runtime) -> [String]? {
        guard let strips = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: runtime.ax)?.strips else { return nil }
        let names = strips.map { AXHelpers.getDescription($0, runtime: runtime.ax) ?? "" }
        return names.contains("") ? nil : names
    }
}

/// Pure comparison of two Mixer strip censuses for `mixer.create_aux`.
enum CreateAuxVerifier {
    enum Verdict: Equatable, Sendable {
        case created(name: String, position: Int)
        case unchanged
        case unexpected(String)
    }

    /// Names present more often after than before (a multiset difference).
    static func added(before: [String], after: [String]) -> [String] {
        var counts = Dictionary(before.map { ($0, 1) }, uniquingKeysWith: +)
        var added: [String] = []
        for name in after {
            if let count = counts[name], count > 0 { counts[name] = count - 1 } else { added.append(name) }
        }
        return added
    }

    static func verdict(before: [String], after: [String]) -> Verdict {
        if after == before { return .unchanged }
        guard after.count == before.count + 1 else {
            return .unexpected("strip count went from \(before.count) to \(after.count)")
        }
        let added = added(before: before, after: after)
        guard added.count == 1 else { return .unexpected("\(added.count) strips changed") }
        // Every strip that was there is still there, in its order.
        var remaining = after
        if let index = remaining.lastIndex(of: added[0]) { remaining.remove(at: index) }
        guard remaining == before else { return .unexpected("existing strips changed order or name") }
        return .created(name: added[0], position: after.lastIndex(of: added[0]) ?? -1)
    }
}
