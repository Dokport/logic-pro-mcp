@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    @TaskLocal static var inputChangeObserver: (@Sendable (ChangedInputObservation) -> Void)?

    /// Native custody of this request's actual input change; never reconstructed from JSON.
    struct ChangedInputObservation: @unchecked Sendable {
        let original: HeldSelectionAssociation.Pair
        let current: HeldSelectionAssociation.Pair
        let renewal: OriginalHeaderSourceRenewal?
        let control: AXMixerInputSlotBinding
        let population: [AXUIElement]
        let sink: OutputAssignment
        let before: Int
        let after: Int
        let focus: AXUIElement
        let checkedAfter: CheckedOutputReading
        let sampledAt: String

        func permits() -> Bool {
            let runtime = current.track.runtime
            guard before != after, (1...256).contains(before), (1...256).contains(after),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  original.track.matches(current.track),
                  renewal.map({ $0.pair.track.matches(current.track) && $0.pair.strip.matches(current.strip)
                    && $0.permits(runtime: runtime) }) ?? original.strip.matches(current.strip),
                  current.track.currentIndex() != nil, current.strip.currentIndex(runtime: runtime) != nil,
                  current.track.document.utf8.elementsEqual(current.strip.document.utf8),
                  let pid = runtime.logicProPID(), runtime.focusedApplicationPID() == pid,
                  let app = AXLogicProElements.appRoot(runtime: runtime),
                  AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: runtime.ax) as Bool? == true,
                  let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: runtime.ax),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: runtime.ax),
                  CFEqual(main, current.strip.window), CFEqual(focusedWindow, current.strip.window),
                  let currentFocus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                  CFEqual(currentFocus, focus), renewal != nil || readLogicKeyboardFocus(of: focus, runtime: runtime) == .notTextEditing,
                  AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportPlayControl, runtime: runtime) == false,
                  AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportRecordControl, runtime: runtime) == false,
                  !AXLogicProElements.dialogPresenceReason(runtime: runtime).isBlocked,
                  let census = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: current.strip.mixer, runtime: runtime.ax)?.strips,
                  census.count == population.count, zip(census, population).allSatisfy({ CFEqual($0, $1) }),
                  census.filter({ CFEqual($0, current.strip.strip) }).count == 1,
                  let sends = AXLogicProElements.sendSlotObservations(in: current.strip.strip, runtime: runtime.ax),
                  sends.allSatisfy({ $0.state == .observedEmpty }),
                  let output = AXLogicProElements.outputSlotDestination(in: current.strip.strip, runtime: runtime.ax),
                  OutputAssignment.observed(slotLabel: output) == sink else { return false }
            let input = AXLogicProElements.inputSlotRead(in: current.strip.strip, runtime: runtime.ax)
            guard case .source(let label) = input.reading, let element = input.control,
                  control.matches(.init(owner: current.strip, control: element, source: label)) else { return false }
            return (renewal?.permits(runtime: runtime) ?? true)
                && current.track.currentIndex() != nil && current.strip.currentIndex(runtime: runtime) != nil
                && (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
        }

        /// The scalar already obtained an independent checked read after its write.
        /// Keep that native observation, not a decoded receipt or a new timestamp.
        /// A redundant popup/Cancel can retire unrelated peers and destroy custody.
        func retainedCheckedRead() -> CheckedOutputReading? {
            guard checkedAfter.assignment == .bus(after),
                  checkedAfter.inputSlot.map(control.matches) == true, permits() else { return nil }
            var reading = checkedAfter
            reading.inputRenewal = renewal
            return reading
        }
    }

    static func recordInputEffect(original: HeldSelectionAssociation.Pair?, current: HeldSelectionAssociation.Pair?,
        renewal: OriginalHeaderSourceRenewal?, control: AXMixerInputSlotBinding, population: [AXUIElement], sink: OutputAssignment,
        before: Int, after: Int, checkedAfter: CheckedOutputReading, runtime: AXLogicProElements.Runtime) -> Bool {
        guard let observer = inputChangeObserver else { return true }
        guard let original, let current, current.strip.matches(control.owner),
              checkedAfter.assignment == .bus(after), checkedAfter.inputSlot.map(control.matches) == true,
              let app = AXLogicProElements.appRoot(runtime: runtime),
              let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax) else { return false }
        let proof = ChangedInputObservation(original: original, current: current, renewal: renewal, control: control,
            population: population, sink: sink, before: before, after: after, focus: focus,
            checkedAfter: checkedAfter, sampledAt: ISO8601DateFormatter.cacheFormatter.string(from: Date()))
        guard proof.permits() else { return false }
        observer(proof)
        return true
    }
}
