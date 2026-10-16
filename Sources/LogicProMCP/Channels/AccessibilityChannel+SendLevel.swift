@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    /// These semantic editor values, not a raw-slider conversion or a universal
    /// dB range, have been exercised on the occupied native Send editor.
    static func sendLevelToken(_ text: String) -> String? {
        switch text {
        case "-95", "-95.0": "-95"
        case "-6", "-6.0": "-6"
        case "-∞": "-∞"
        default: nil
        }
    }

    private static func sendLevelSlotsMatch(_ lhs: [SendSlotObservation], _ rhs: [SendSlotObservation],
        ordinal: Int, allowingLevelChange: Bool) -> Bool {
        var left = lhs, right = rhs
        if allowingLevelChange {
            for index in left.indices where left[index].ordinal == ordinal {
                left[index].levelRaw = nil; left[index].levelDescription = nil
            }
            for index in right.indices where right[index].ordinal == ordinal {
                right[index].levelRaw = nil; right[index].levelDescription = nil
            }
        }
        return left == right
    }

    static func setSendLevelVerified(params: [String: String], runtime: AXLogicProElements.Runtime,
        mouse: AXMouseHelper.Runtime?, canPostEvents: @escaping @Sendable () -> Bool) async -> ChannelResult {
        var extras: [String: Any] = ["operation": "mixer.set_send_level_verified", "write_attempted": false,
            "snapshot_atomic": false]
        func refused(_ error: HonestContract.FailureError, _ hint: String) -> ChannelResult {
            if extras["write_attempted"] as? Bool == true {
                extras["hint"] = hint
                return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
            }
            return .error(HonestContract.encodeStateC(error: error, hint: hint, extras: extras))
        }
        guard params.keys.allSatisfy({ ["ordinal", "level_db", "expected_current"].contains($0) }),
              let ordinal = params["ordinal"].flatMap(Int.init), ordinal >= 0,
              let text = params["level_db"], let desired = sendLevelToken(text),
              let expectedText = params["expected_current"], let expected = sendLevelToken(expectedText) else {
            return refused(.invalidParams, "Only the qualified semantic Send levels -95, -6 and -∞ (including .0 normalization) are supported.")
        }
        extras["send_ordinal"] = ordinal
        func numericRaw(_ knob: AXUIElement) -> Double? {
            let reading: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(knob,
                kAXValueAttribute as String, runtime: runtime.ax)
            guard case .success(let value?) = reading, CFGetTypeID(value) == CFNumberGetTypeID(),
                  let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }
        guard let before = await readSendBypassSnapshot(ordinal: ordinal, runtime: runtime),
              let knob = before.control.level, let app = AXLogicProElements.appRoot(runtime: runtime),
              let slot = before.slots.first(where: { $0.ordinal == ordinal }),
              let display = slot.levelDescription, let current = sendLevelToken(display),
              let raw = slot.levelRaw, raw.isFinite, numericRaw(knob) == raw else {
            return refused(.readbackUnavailable, "The exact occupied knob, semantic display, checked route and protected state must all be observed.")
        }
        extras["before"] = display; extras["level_db"] = display; extras["level_raw"] = raw
        extras["checked_destination"] = before.assignment.json
        extras["protected_nonrouting_titles"] = before.checks
        func windows() -> [AXUIElement]? {
            guard case .success(.elements(let value)) = AXHelpers.getAXUIElementArrayRead(app,
                kAXWindowsAttribute as String, runtime: runtime.ax) else { return nil }
            return value
        }
        func custody(allowingLevelChange: Bool = false) -> Bool {
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let pid = runtime.logicProPID(), runtime.focusedApplicationPID() == pid,
                  before.physical.currentIndex(runtime: runtime) != nil,
                  let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: runtime.ax),
                  CFEqual(main, before.physical.window),
                  let control = AXLogicProElements.assignedSendMenuControl(in: before.physical.strip, ordinal: ordinal, runtime: runtime.ax),
                  before.control.matches(control),
                  let slots = AXLogicProElements.sendSlotObservations(in: before.physical.strip, runtime: runtime.ax),
                  sendLevelSlotsMatch(before.slots, slots, ordinal: ordinal, allowingLevelChange: allowingLevelChange),
                  let population = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: before.physical.mixer, runtime: runtime.ax)?.strips,
                  population.count == before.population.count,
                  zip(population, before.population).allSatisfy({ CFEqual($0, $1) }) else { return false }
            return (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
        }
        func stopped() -> Bool {
            AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportPlayControl, runtime: runtime) == false
                && AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportRecordControl, runtime: runtime) == false
        }
        var observedOwnSourceFocus = false
        func ordinaryFocus() -> Bool {
            guard let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                  CFEqual(focus, before.focus) || CFEqual(focus, knob)
                    || (observedOwnSourceFocus && CFEqual(focus, before.physical.strip)),
                  let window: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: runtime.ax),
                  CFEqual(window, before.physical.window) else { return false }
            return AXHelpers.getRole(focus, runtime: runtime.ax) != kAXTextFieldRole as String
        }
        guard expected == current, custody(), ordinaryFocus() else {
            return refused(.staleSnapshot, "The expected semantic level or original source/focus changed.")
        }
        if desired == current {
            extras["changed"] = false; extras["verify_source"] = "ax_send_level_display"
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        guard let deciding = await readSendBypassSnapshot(ordinal: ordinal, runtime: runtime),
              before.control.matches(deciding.control), deciding.slots == before.slots,
              deciding.assignment == before.assignment, deciding.checks == before.checks else {
            return refused(.staleSnapshot, "The independent deciding route, mode, level or control changed before editor acquisition.")
        }
        guard let mouse, canPostEvents(), stopped(), custody(), ordinaryFocus(),
              let originalWindows = windows(),
              originalWindows.filter({ CFEqual($0, before.physical.window) }).count == 1,
              let position = AXHelpers.getPosition(knob, runtime: runtime.ax),
              let size = AXHelpers.getSize(knob, runtime: runtime.ax),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, let hitTest = runtime.ax.elementAtPosition else {
            return refused(.unsupportedState, "A stopped, owned exact-knob numeric editor transport is required.")
        }
        let originalPair = AXMixerStripBinding.outputAssociation
        let observingEffect = sendLevelChangeObserver != nil
        var peerFootprints: [[SendSlotObservation]] = []
        if observingEffect {
            guard let originalPair, originalPair.strip.matches(before.physical) else {
                return refused(.staleSnapshot, "Native level effect observation requires the retained original-header pair.")
            }
            for strip in before.population {
                guard let slots = AXLogicProElements.sendSlotObservations(in: strip, runtime: runtime.ax) else {
                    return refused(.readbackUnavailable, "Native level effect observation requires complete peer Send footprints.")
                }
                peerFootprints.append(slots)
            }
        }
        // One native double-click, not AXValue stepping or a popup fallback.
        let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        for count: Int64 in [1, 2] {
            guard let click = mouse.prepareMouseClick(point, count), stopped(), custody(), ordinaryFocus(),
                  AXHelpers.getPosition(knob, runtime: runtime.ax) == position,
                  AXHelpers.getSize(knob, runtime: runtime.ax) == size,
                  case .success(.some(let hit)) = hitTest(app, point), CFEqual(hit, knob),
                  stopped(), custody(), ordinaryFocus(),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                return refused(.staleSnapshot, "The exact knob frame, hit or custody changed before editor acquisition.")
            }
            guard click.postDown() else { return refused(.readbackUnavailable, "Numeric editor mouse-down was not accepted.") }
            guard click.postUp() else { return refused(.readbackUnavailable, "Numeric editor paired release was not accepted.") }
            if count == 1 {
                // Logic's first exact-knob click can land on its containing
                // physical strip before the second click opens the editor.
                // Observe only this actual paired-click transition; another
                // strip, editor or document never gains focus authority.
                if let focus: AXUIElement = AXHelpers.getAttribute(app,
                    kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                   CFEqual(focus, before.physical.strip), !CFEqual(focus, before.focus) {
                    observedOwnSourceFocus = true
                    extras["ui_effects"] = ["navigation_performed": true,
                        "attempted": ["send_numeric_editor"], "changed": ["keyboard_focus"],
                        "restoration": "not_restored"]
                }
                mouse.sleepMicros(40_000)
            }
        }
        guard custody(), let members = windows(),
              let editorWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: runtime.ax),
              !CFEqual(editorWindow, before.physical.window),
              !originalWindows.contains(where: { CFEqual($0, editorWindow) }),
              members.filter({ CFEqual($0, editorWindow) }).count == 1,
              members.filter({ CFEqual($0, before.physical.window) }).count == 1,
              case .success(let census) = AXHelpers.censusDescendantResult(of: editorWindow,
                role: kAXTextFieldRole, maxDepth: 6, runtime: runtime.ax, requiresCompleteTraversal: true),
              census.matches.count == 1, let field = census.matches.first else {
            return refused(.readbackUnavailable, "The acquired numeric editor window and unique field were not proved.")
        }
        var committedFocusReturned = false
        func ownsField(_ expectedValue: String, allowingLevelChange: Bool = false) -> Bool {
            guard stopped(), custody(allowingLevelChange: allowingLevelChange), let members = windows(),
                  members.filter({ CFEqual($0, editorWindow) }).count == 1,
                  let fieldWindow: AXUIElement = AXHelpers.getAttribute(field, kAXWindowAttribute as String, runtime: runtime.ax),
                  CFEqual(fieldWindow, editorWindow),
                  let value: String = AXHelpers.getAttribute(field, kAXValueAttribute as String, runtime: runtime.ax),
                  sendLevelToken(value) == expectedValue,
                  AXHelpers.isAttributeSettable(field, kAXValueAttribute as String, runtime: runtime.ax) == true,
                  stopped(), custody(allowingLevelChange: allowingLevelChange),
                  let window: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: runtime.ax) else { return false }
            // Return may close the editor between the held-field reads and this
            // window read. Only this proved transition may settle here; a prior
            // failed ownership check must never be revived by later focus.
            if allowingLevelChange, CFEqual(window, before.physical.window) {
                guard stopped(), custody(allowingLevelChange: true), ordinaryFocus(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
                committedFocusReturned = true
                return true
            }
            guard CFEqual(window, editorWindow),
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                  CFEqual(focus, field) else { return false }
            return (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
        }
        guard ownsField(expected) else { return refused(.staleSnapshot, "The deciding exact editor field or expected level changed.") }
        extras["write_attempted"] = true
        let accepted = AXHelpers.setAttribute(field, kAXValueAttribute as String, text as CFTypeRef, runtime: runtime.ax)
        guard accepted, ownsField(desired) else { return refused(.readbackUnavailable, "The owned editor value setter was not independently observed.") }
        guard mouse.postKeyEvent(36) else { return refused(.readbackUnavailable, "The owned editor commit was not accepted.") }
        // Return can acknowledge before its exact numeric editor releases focus.
        // Wait only inside that still-owned editor; never repeat a data action,
        // wait through foreign focus, or widen the request's existing deadline.
        for attempt in 0..<3 {
            if ordinaryFocus() { break }
            guard ownsField(desired, allowingLevelChange: true) else {
                return refused(.readbackUnavailable, "The pending commit lost its exact editor field/window or protected source; no inverse was guessed.")
            }
            if committedFocusReturned { break }
            if attempt < 2 { mouse.sleepMicros(25_000) }
        }
        guard custody(allowingLevelChange: true), ordinaryFocus(),
              let after = await readSendBypassSnapshot(ordinal: ordinal, runtime: runtime),
              before.control.matches(after.control), before.assignment == after.assignment,
              before.checks == after.checks,
              sendLevelSlotsMatch(before.slots, after.slots, ordinal: ordinal, allowingLevelChange: true),
              let observed = after.slots.first(where: { $0.ordinal == ordinal }),
              let afterDisplay = observed.levelDescription, sendLevelToken(afterDisplay) == desired,
              let afterRaw = observed.levelRaw, afterRaw.isFinite, numericRaw(knob) == afterRaw,
              custody(allowingLevelChange: true), ordinaryFocus(),
              AXLogicProElements.sendSlotObservations(in: before.physical.strip, runtime: runtime.ax) == after.slots,
              before.physical.currentIndex(runtime: runtime) != nil,
              (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
            return refused(.readbackUnavailable, "Independent same-knob level and protected after-state were not verified; no inverse was guessed.")
        }
        extras["level_db"] = afterDisplay; extras["level_raw"] = afterRaw
        extras["changed"] = true; extras["verify_source"] = "ax_owned_send_numeric_editor"
        if observingEffect {
            guard let originalPair,
                  let observation = HeldSelectionAssociation(window: originalPair.strip.window, logic: runtime,
                    expectedProject: nil, requiresProjectReference: false, allowsSelectedChildRailEntry: true) else {
                return refused(.readbackUnavailable, "The actual level commit lost its original-header observation.")
            }
            for index in before.population.indices {
                if CFEqual(before.population[index], before.physical.strip) { peerFootprints[index] = after.slots }
            }
            let proof = ChangedSendLevelObservation(pair: originalPair, snapshot: after,
                peerFootprints: peerFootprints, before: current, after: desired, observation: observation,
                mouse: mouse, canPostEvents: canPostEvents)
            guard proof.permits() else {
                return refused(.readbackUnavailable, "The actual level commit lost native control, peer or numeric custody before publication.")
            }
            sendLevelChangeObserver?(proof)
        }
        return .success(HonestContract.encodeStateA(extras: extras))
    }
}
