@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    @TaskLocal static var sendCreationObserver: (@Sendable (CreatedSendObservation) -> Void)?

    /// The exact occupied control produced by our sole-empty creation, not an
    /// existing Send adopted from a receipt, label or new public reference.
    struct CreatedSendObservation: @unchecked Sendable {
        let source: OriginalHeaderSourceRenewal
        let control: AXLogicProElements.AssignedSendMenuControl
        let footprint: [SendSlotObservation]
        let nonRoutingChecks: [String]
        let mode: SendModeState
        let population: [AXUIElement]
        let beforePeers: [[SendSlotObservation]]
        let afterPeers: [[SendSlotObservation]]

        func permits(runtime: AXLogicProElements.Runtime, ownedPopup: AXUIElement? = nil) -> Bool {
            guard source.permits(runtime: runtime, ownedPopup: ownedPopup),
                  mode.mode == .postFader, !mode.independentPan, mode.otherChecks.isEmpty,
                  let current = AXLogicProElements.assignedSendMenuControl(in: source.pair.strip.strip,
                    ordinal: control.ordinal, runtime: runtime.ax), control.matches(current),
                  AXLogicProElements.sendSlotObservations(in: source.pair.strip.strip, runtime: runtime.ax) == footprint,
                  let slot = footprint.first(where: { $0.ordinal == control.ordinal }),
                  slot.levelRaw == 0, slot.bypassed == false, let knob = control.level,
                  let census = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: source.pair.strip.mixer,
                    runtime: runtime.ax)?.strips, census.count == population.count,
                  beforePeers.count == census.count, afterPeers.count == census.count,
                  zip(census, population).allSatisfy({ CFEqual($0, $1) }) else { return false }
            let raw: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(knob,
                kAXValueAttribute as String, runtime: runtime.ax)
            guard case .success(.some(let value)) = raw, CFGetTypeID(value) == CFNumberGetTypeID(),
                  let number = value as? NSNumber, number.doubleValue == 0 else { return false }
            for index in census.indices {
                guard AXLogicProElements.sendSlotObservations(in: census[index], runtime: runtime.ax) == afterPeers[index] else { return false }
            }
            return source.permits(runtime: runtime, ownedPopup: ownedPopup)
        }

        /// The inverse's own returned empty control is observed independently.
        /// A retired created control never supplies authority for its replacement.
        func permitsRemoval(_ removed: RemovedSendObservation, runtime: AXLogicProElements.Runtime) -> Bool {
            guard removed.source.original.matches(source.pair.strip),
                  removed.source.originalTrack.matches(source.pair.track),
                  removed.checkedDestination == .stereoOutput, removed.nonRoutingChecks == nonRoutingChecks,
                  let before = footprint.first(where: { $0.ordinal == control.ordinal }), removed.before == before,
                  removed.permits(runtime: runtime),
                  let census = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: removed.source.pair.strip.mixer,
                    runtime: runtime.ax)?.strips, census.count == population.count,
                  beforePeers.count == census.count,
                  population.filter({ CFEqual($0, source.pair.strip.strip) }).count == 1 else { return false }
            let expected = population.map { CFEqual($0, source.pair.strip.strip) ? removed.source.pair.strip.strip : $0 }
            guard zip(census, expected).allSatisfy({ CFEqual($0, $1) }) else { return false }
            for index in census.indices where !CFEqual(census[index], removed.source.pair.strip.strip) {
                guard AXLogicProElements.sendSlotObservations(in: census[index], runtime: runtime.ax) == beforePeers[index] else { return false }
            }
            return removed.permits(runtime: runtime)
        }
    }
}
