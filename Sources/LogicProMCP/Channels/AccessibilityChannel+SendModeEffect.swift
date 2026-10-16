@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    @TaskLocal static var sendModeChangeObserver: (@Sendable (ChangedSendModeObservation) -> Void)?

    /// Request-local mode effect custody, distinct from assignment/removal proof.
    struct ChangedSendModeObservation: @unchecked Sendable {
        let original: HeldSelectionAssociation.Pair
        let current: HeldSelectionAssociation.Pair
        let renewal: OriginalHeaderSourceRenewal?
        let control: AXLogicProElements.AssignedSendMenuControl
        let footprint: [SendSlotObservation]
        let population: [AXUIElement]
        let peerFootprints: [[SendSlotObservation]]
        let checkedDestination: OutputAssignment
        let before: SendModeState
        let after: SendModeState
        let observation: HeldSelectionAssociation

        /// Custody only: an inverse still needs a new checked mode-menu read.
        func permits(runtime: AXLogicProElements.Runtime) -> Bool {
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  observation.permitsRead(), original.track.matches(current.track),
                  current.track.currentIndex() != nil, current.strip.currentIndex(runtime: runtime) != nil,
                  current.track.document.utf8.elementsEqual(current.strip.document.utf8),
                  before.mode != after.mode, before.mode == .postFader || after.mode == .postFader,
                  before.independentPan == after.independentPan, before.otherChecks == after.otherChecks else { return false }
            if let renewal {
                guard renewal.original.matches(original.strip), renewal.originalTrack.matches(original.track),
                      renewal.pair.track.matches(current.track), renewal.pair.strip.matches(current.strip),
                      renewal.permits(runtime: runtime) else { return false }
            } else if !original.strip.matches(current.strip) { return false }
            guard let held = AXLogicProElements.assignedSendMenuControl(in: current.strip.strip,
                    ordinal: control.ordinal, runtime: runtime.ax), control.matches(held),
                  AXLogicProElements.sendSlotObservations(in: current.strip.strip, runtime: runtime.ax) == footprint,
                  let census = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: current.strip.mixer,
                    runtime: runtime.ax)?.strips,
                  census.count == population.count, peerFootprints.count == census.count,
                  zip(census, population).allSatisfy({ CFEqual($0, $1) }),
                  census.filter({ CFEqual($0, current.strip.strip) }).count == 1 else { return false }
            guard let level = control.level,
                  let expectedLevel = footprint.first(where: { $0.ordinal == control.ordinal })?.levelRaw else { return false }
            let rawLevel: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(level,
                kAXValueAttribute as String, runtime: runtime.ax)
            guard case .success(.some(let raw)) = rawLevel, CFGetTypeID(raw) == CFNumberGetTypeID(),
                  let number = raw as? NSNumber, number.doubleValue.isFinite,
                  number.doubleValue == expectedLevel else { return false }
            for index in census.indices {
                guard AXLogicProElements.sendSlotObservations(in: census[index], runtime: runtime.ax) == peerFootprints[index] else { return false }
            }
            return observation.permitsRead() && (renewal?.permits(runtime: runtime) ?? true)
                && (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
        }
    }

    static func recordSendModeEffect(original: HeldSelectionAssociation.Pair?,
        renewal: OriginalHeaderSourceRenewal?, control: AXLogicProElements.AssignedSendMenuControl,
        footprint: [SendSlotObservation], population: [AXUIElement]?, peerFootprints: [[SendSlotObservation]]?,
        destination: OutputAssignment?, before: SendModeState?, after: SendModeState?,
        runtime: AXLogicProElements.Runtime) -> Bool {
        guard let observer = sendModeChangeObserver else { return true }
        guard let original, let population, let peerFootprints, let destination, let before, let after else { return false }
        let current = renewal?.pair ?? original
        guard let observation = HeldSelectionAssociation(window: current.strip.window, logic: runtime,
            expectedProject: nil, requiresProjectReference: false, allowsSelectedChildRailEntry: true) else { return false }
        let proof = ChangedSendModeObservation(original: original, current: current, renewal: renewal,
            control: control, footprint: footprint, population: population, peerFootprints: peerFootprints,
            checkedDestination: destination, before: before, after: after, observation: observation)
        guard proof.permits(runtime: runtime) else { return false }
        observer(proof)
        return true
    }
}
