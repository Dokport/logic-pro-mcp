@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    @TaskLocal static var sendLevelChangeObserver: (@Sendable (ChangedSendLevelObservation) -> Void)?

    /// Native custody of one actual editor commit, never reconstructible from its JSON result.
    struct ChangedSendLevelObservation: @unchecked Sendable {
        let pair: HeldSelectionAssociation.Pair
        let snapshot: SendBypassSnapshot
        let peerFootprints: [[SendSlotObservation]]
        let before: String
        let after: String
        let observation: HeldSelectionAssociation
        let mouse: AXMouseHelper.Runtime
        let canPostEvents: @Sendable () -> Bool

        func permits() -> Bool {
            let runtime = pair.track.runtime
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  observation.permitsRead(), pair.strip.matches(snapshot.physical),
                  pair.track.currentIndex() != nil, pair.strip.currentIndex(runtime: runtime) != nil,
                  pair.track.document.utf8.elementsEqual(pair.strip.document.utf8), before != after,
                  let control = AXLogicProElements.assignedSendMenuControl(in: pair.strip.strip,
                    ordinal: snapshot.control.ordinal, runtime: runtime.ax), snapshot.control.matches(control),
                  AXLogicProElements.sendSlotObservations(in: pair.strip.strip, runtime: runtime.ax) == snapshot.slots,
                  let population = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: pair.strip.mixer,
                    runtime: runtime.ax)?.strips,
                  population.count == snapshot.population.count, peerFootprints.count == population.count,
                  zip(population, snapshot.population).allSatisfy({ CFEqual($0, $1) }),
                  population.filter({ CFEqual($0, pair.strip.strip) }).count == 1,
                  let knob = control.level,
                  let slot = snapshot.slots.first(where: { $0.ordinal == control.ordinal }),
                  slot.levelDescription.flatMap(sendLevelToken) == after,
                  let expectedRaw = slot.levelRaw else { return false }
            let read: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(knob,
                kAXValueAttribute as String, runtime: runtime.ax)
            guard case .success(.some(let value)) = read, CFGetTypeID(value) == CFNumberGetTypeID(),
                  let number = value as? NSNumber, number.doubleValue.isFinite,
                  number.doubleValue == expectedRaw else { return false }
            for index in population.indices {
                guard AXLogicProElements.sendSlotObservations(in: population[index], runtime: runtime.ax) == peerFootprints[index] else { return false }
            }
            return observation.permitsRead() && (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
        }
    }
}
