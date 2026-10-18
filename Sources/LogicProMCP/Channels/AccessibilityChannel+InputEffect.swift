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

        /// Follow only this checked read's original-header renewal, never a public ref or label.
        func following(_ read: CheckedOutputReading) -> Self? {
            guard read.assignment == .bus(after), let slot = read.inputSlot else { return nil }
            guard let next = read.inputRenewal else {
                return permits() && control.matches(slot) ? self : nil
            }
            let runtime = current.track.runtime
            guard next.original.matches(current.strip), next.originalTrack.matches(current.track),
                  next.pair.track.matches(current.track), next.permits(runtime: runtime),
                  slot.owner.matches(next.pair.strip),
                  let census = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: next.pair.strip.mixer, runtime: runtime.ax)?.strips,
                  census.count == population.count,
                  zip(population, census).allSatisfy({ old, new in
                      CFEqual(old, current.strip.strip) ? CFEqual(new, next.pair.strip.strip) : CFEqual(old, new)
                  }),
                  let app = AXLogicProElements.appRoot(runtime: runtime),
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax) else { return nil }
            let renewed = Self(original: original, current: next.pair, renewal: next, control: slot,
                population: census, sink: sink, before: before, after: after, focus: focus)
            return renewed.permits() ? renewed : nil
        }
    }

    static func recordInputEffect(original: HeldSelectionAssociation.Pair?, current: HeldSelectionAssociation.Pair?,
        renewal: OriginalHeaderSourceRenewal?, control: AXMixerInputSlotBinding, population: [AXUIElement], sink: OutputAssignment,
        before: Int, after: Int, runtime: AXLogicProElements.Runtime) -> Bool {
        guard let observer = inputChangeObserver else { return true }
        guard let original, let current, current.strip.matches(control.owner),
              let app = AXLogicProElements.appRoot(runtime: runtime),
              let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax) else { return false }
        let proof = ChangedInputObservation(original: original, current: current, renewal: renewal, control: control,
            population: population, sink: sink, before: before, after: after, focus: focus)
        guard proof.permits() else { return false }
        observer(proof)
        return true
    }
}
