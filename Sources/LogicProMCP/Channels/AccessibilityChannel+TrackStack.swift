import ApplicationServices
import Foundation

/// `track.create_stack`: select exactly the named tracks, Track > Create Track Stack…, pick the
/// kind in the sheet, press its default button, and read the whole rail back.
///
/// Measured on Logic 12.4 (`research/FINDINGS.md`): the menu item and the sheet's controls are
/// all AX-pressable; setting `AXSelectedChildren` on the track rail selects only one row, so the
/// further members are added with a ⌘-click on each one's AX-located name field, and every row's
/// `AXSelected` is read back as exactly the members before the menu is pressed. A summing stack's
/// main track is an aux fed by a new bus, and Logic routes the members' outputs to that bus.
extension AccessibilityChannel {
    private static let trackStackSheetPolls = 20
    private static let trackStackPollMicros: UInt32 = 100_000

    static func defaultCreateTrackStack(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        func refuse(_ error: HonestContract.FailureError, _ reason: String, _ hint: String, _ extras: [String: Any] = [:]) -> ChannelResult {
            var details = extras
            details["operation"] = "track.create_stack_verified"
            details["reason"] = reason
            details["write_attempted"] = false
            return .error(HonestContract.encodeStateC(error: error, hint: hint, extras: details))
        }
        guard let kind = params["kind"].flatMap(TrackStackKind.init(rawValue:)) else {
            return refuse(.invalidParams, "kind_invalid", "create_stack 'kind' must be folder or summing")
        }
        guard let raw = params["members_json"], let data = raw.data(using: .utf8),
              let members = try? JSONDecoder().decode([String].self, from: data) else {
            return refuse(.invalidParams, "members_invalid", "create_stack requires members as a JSON array of track names")
        }
        var evidence: [String: Any] = ["kind": kind.rawValue, "members": members]

        // 1. The whole rail, strictly read, and the members by exact unique name.
        guard case .read(let before) = trackStackRailRead(runtime: runtime) else {
            return refuse(.readbackUnavailable, "rail_unreadable", "The track list could not be read completely; nothing was selected.", evidence)
        }
        let beforeNames = before.map(\.name)
        evidence["before_order"] = beforeNames
        guard !before.contains(where: { $0.isStackHeader == nil }) else {
            return refuse(.readbackUnavailable, "stack_state_unreadable",
                "A track's stack state did not read, so the rail cannot be compared afterwards; nothing was selected.", evidence)
        }
        let memberIndices: [Int]
        switch TrackStackVerifier.resolveMembers(members, in: beforeNames) {
        case .resolved(let indices):
            memberIndices = indices
        case .missing(let names):
            evidence["missing_members"] = names
            return refuse(.elementNotFound, "member_not_found", "No track is named \(names.joined(separator: ", ")).", evidence)
        case .ambiguous(let names):
            evidence["ambiguous_members"] = names
            return refuse(.ambiguousTargetName, "member_ambiguous",
                "More than one track is named \(names.joined(separator: ", ")); rename them so each member is unique.", evidence)
        case .duplicateMembers(let names):
            return refuse(.invalidParams, "duplicate_members", "Members are listed twice: \(names.joined(separator: ", ")).", evidence)
        case .tooFew:
            return refuse(.invalidParams, "no_members", "create_stack needs at least one member.", evidence)
        }
        evidence["member_indices"] = memberIndices
        if let stack = memberIndices.first(where: { before[$0].isStackHeader == true }) {
            return refuse(.unsupportedState, "member_is_stack",
                "'\(beforeNames[stack])' is already a stack main track; nesting is not supported here.", evidence)
        }

        // 2. Logic in front, then exactly the members selected.
        let front = FrontmostGate.prepareObserved(
            observe: runtime.observeFrontmost,
            activate: { ProcessUtils.activateLogicPro() },
            sleepMicros: { usleep($0) }
        )
        guard front.preparation.isReady else {
            return refuse(.unsupportedState, "logic_not_frontmost", "Logic Pro could not be brought to the front; nothing was selected.", evidence)
        }
        guard AXLogicProElements.selectTrackViaAX(at: memberIndices[0], runtime: runtime),
              await verifyTrackSelection(index: memberIndices[0], runtime: runtime) == .verified else {
            return refuse(.trackSelectionFailed, "select_failed", "The first member could not be selected alone; nothing was created.", evidence)
        }
        for index in memberIndices.dropFirst() {
            guard let point = trackStackNameFieldPoint(before[index].header, runtime: runtime) else {
                evidence["not_clickable_member"] = beforeNames[index]
                return refuse(.unsupportedState, "member_not_visible",
                    "'\(beforeNames[index])' is not visible in the track list, so it cannot be added to the selection. Close the Mixer or scroll and retry; nothing was created.",
                    evidence)
            }
            AXMouseHelper.commandClick(at: point)
            usleep(120_000)
        }
        usleep(150_000)
        let selected = trackStackSelectedRows(runtime: runtime)
        evidence["selected_indices"] = selected ?? NSNull()
        guard let selected, selected == memberIndices else {
            return refuse(.trackSelectionFailed, "selection_not_exact",
                "The track selection did not read back as exactly the members; nothing was created.", evidence)
        }

        // 3. The menu item, then the sheet: kind by its measured position, then the default button.
        guard case .found(let item) = AXLogicProElements.menuItemRead(
            labelPath: [AXLocalePolicy.createTrackStackMenuPath.bar, AXLocalePolicy.createTrackStackMenuPath.item],
            runtime: runtime
        ) else {
            return refuse(.elementNotFound, "menu_item_absent", "Track > Create Track Stack… was not found.", evidence)
        }
        let enabled: Bool? = AXHelpers.getAttribute(item, kAXEnabledAttribute as String, runtime: runtime.ax)
        guard enabled == true else {
            return refuse(.unsupportedState, "menu_item_disabled", "Create Track Stack… is not enabled for this selection.", evidence)
        }
        _ = AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax)
        var sheet: AXUIElement?
        for _ in 0..<trackStackSheetPolls {
            if let found = trackStackSheet(runtime: runtime) { sheet = found; break }
            usleep(trackStackPollMicros)
        }
        guard let sheet else {
            return refuse(.dialogNotFound, "sheet_not_observed", "The stack-type sheet did not appear; nothing was created.", evidence)
        }
        let radios = AXHelpers.getChildren(sheet, runtime: runtime.ax)
            .filter { AXHelpers.getRole($0, runtime: runtime.ax) == kAXRadioButtonRole as String }
        guard radios.count == TrackStackKind.allCases.count,
              let create: AXUIElement = AXHelpers.getAttribute(sheet, kAXDefaultButtonAttribute as String, runtime: runtime.ax),
              let cancel: AXUIElement = AXHelpers.getAttribute(sheet, kAXCancelButtonAttribute as String, runtime: runtime.ax) else {
            AXMouseHelper.pressEscape()
            return refuse(.unsupportedState, "sheet_layout_unrecognized",
                "The stack-type sheet is not the measured one (two kinds, a default and a cancel button); it was cancelled.", evidence)
        }
        let radio = radios[kind.radioIndex]
        evidence["kind_label"] = AXHelpers.getTitle(radio, runtime: runtime.ax) ?? NSNull()
        _ = AXHelpers.performAction(radio, kAXPressAction as String, runtime: runtime.ax)
        usleep(100_000)
        let chosen = (AXHelpers.getValue(radio, runtime: runtime.ax) as? NSNumber)?.intValue
        guard chosen == 1 else {
            _ = AXHelpers.performAction(cancel, kAXPressAction as String, runtime: runtime.ax)
            return refuse(.axWriteFailed, "kind_not_selected", "The \(kind.rawValue) option did not read as chosen; the sheet was cancelled.", evidence)
        }
        _ = AXHelpers.performAction(create, kAXPressAction as String, runtime: runtime.ax)
        evidence["write_attempted"] = true

        // 4. The whole rail again, against the measured shape.
        var verdict = TrackStackVerifier.Verdict.unchanged
        var afterNames: [String] = []
        for _ in 0..<trackStackSheetPolls {
            usleep(trackStackPollMicros)
            guard case .read(let after) = trackStackRailRead(runtime: runtime) else { continue }
            afterNames = after.map(\.name)
            verdict = TrackStackVerifier.verify(
                before: beforeNames,
                memberIndices: memberIndices,
                after: after.map { .init(name: $0.name, isStackHeader: $0.isStackHeader) }
            )
            if case .verified = verdict { break }
        }
        evidence["after_order"] = afterNames
        switch verdict {
        case .verified(let headerIndex, let headerName):
            evidence["stack_index"] = headerIndex
            evidence["stack_name"] = headerName
            // Leave exactly the new main track selected, so a following rename acts on it alone:
            // after Create, the main track AND its members are selected, and the AX selection
            // ladder only adds. A plain click on its name field replaces the selection (measured).
            var aloneSelected = false
            var clickPoint: CGPoint?
            if case .read(let rows) = trackStackRailRead(runtime: runtime), headerIndex < rows.count {
                clickPoint = trackStackNameFieldPoint(rows[headerIndex].header, runtime: runtime)
            }
            evidence["stack_click_point"] = clickPoint.map { ["x": $0.x, "y": $0.y] } ?? NSNull()
            if let point = clickPoint {
                // Measured: the first click after the sheet closes can be taken by the window, so
                // up to three clicks, each well outside the double-click interval (a double-click
                // on the name field starts a rename).
                for _ in 0..<3 where !aloneSelected {
                    AXMouseHelper.click(at: point)
                    for _ in 0..<7 {
                        usleep(100_000)
                        if trackStackSelectedRows(runtime: runtime) == [headerIndex] { aloneSelected = true; break }
                    }
                }
            }
            evidence["stack_selected_alone"] = aloneSelected
            evidence["selection_after_click"] = trackStackSelectedRows(runtime: runtime) ?? NSNull()
            return .success(HonestContract.encodeStateA(extras: evidence))
        case .unchanged:
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: evidence.merging(
                ["detail": "the track list did not change after Create"]) { _, new in new }))
        case .mismatch(let why):
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: evidence.merging(
                ["detail": why]) { _, new in new }))
        }
    }

    struct TrackStackRailRow {
        let header: AXUIElement
        let name: String
        let isStackHeader: Bool?
    }

    enum TrackStackRailRead {
        case read([TrackStackRailRow])
        case unreadable
    }

    private static func trackStackRailRead(runtime: AXLogicProElements.Runtime) -> TrackStackRailRead {
        guard case .found(let window) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
              case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime) else {
            return .unreadable
        }
        var rows: [TrackStackRailRow] = []
        for (index, header) in headers.enumerated() {
            let state = AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax)
            guard state.liveIdentityBacked, !state.name.isEmpty else { return .unreadable }
            rows.append(.init(header: header, name: state.name, isStackHeader: state.isStackHeader))
        }
        return .read(rows)
    }

    /// Indices of every row reading `AXSelected` true; nil when any row's flag does not read.
    private static func trackStackSelectedRows(runtime: AXLogicProElements.Runtime) -> [Int]? {
        guard case .read(let rows) = trackStackRailRead(runtime: runtime) else { return nil }
        var selected: [Int] = []
        for (index, row) in rows.enumerated() {
            switch AXHelpers.getAttributeResult(row.header, kAXSelectedAttribute as String, runtime: runtime.ax)
                as Result<NSNumber?, AXHelpers.AXStatusError> {
            case .success(let flag?):
                if flag.boolValue { selected.append(index) }
            case .success(nil):
                continue
            case .failure:
                return nil
            }
        }
        return selected
    }

    /// The middle of a header's name field, only when the whole field lies inside the visible
    /// part of the track list (its scroll area). A row scrolled out of view is not clicked.
    private static func trackStackNameFieldPoint(_ header: AXUIElement, runtime: AXLogicProElements.Runtime) -> CGPoint? {
        guard let field = AXHelpers.getChildren(header, runtime: runtime.ax)
            .first(where: { AXHelpers.getRole($0, runtime: runtime.ax) == kAXTextFieldRole as String }),
              let origin = AXHelpers.getPosition(field, runtime: runtime.ax),
              let size = AXHelpers.getSize(field, runtime: runtime.ax) else { return nil }
        let frame = CGRect(origin: origin, size: size)
        var ancestor: AXUIElement? = AXHelpers.getAttribute(header, kAXParentAttribute as String, runtime: runtime.ax)
        while let current = ancestor, AXHelpers.getRole(current, runtime: runtime.ax) != kAXScrollAreaRole as String {
            ancestor = AXHelpers.getAttribute(current, kAXParentAttribute as String, runtime: runtime.ax)
        }
        guard let scroll = ancestor,
              let scrollOrigin = AXHelpers.getPosition(scroll, runtime: runtime.ax),
              let scrollSize = AXHelpers.getSize(scroll, runtime: runtime.ax),
              CGRect(origin: scrollOrigin, size: scrollSize).contains(frame) else { return nil }
        // Right of the text, so the click selects the row without starting a rename.
        return CGPoint(x: frame.maxX - 8, y: frame.midY)
    }

    /// The main window's sheet with exactly the stack sheet's two radio buttons.
    private static func trackStackSheet(runtime: AXLogicProElements.Runtime) -> AXUIElement? {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime) else { return nil }
        return AXHelpers.getChildren(window, runtime: runtime.ax).first { child in
            AXHelpers.getRole(child, runtime: runtime.ax) == kAXSheetRole as String
                && AXHelpers.getChildren(child, runtime: runtime.ax)
                    .filter { AXHelpers.getRole($0, runtime: runtime.ax) == kAXRadioButtonRole as String }.count == 2
        }
    }
}
