@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    @TaskLocal static var sendRemovalObserver: (@Sendable (RemovedSendObservation) -> Void)?
    @TaskLocal static var sendChangeObserver: (@Sendable (ChangedSendObservation) -> Void)?

    /// Native occupied-slot custody after one independently verified change.
    /// The prior checked destination is inverse data, not permission to act.
    struct ChangedSendObservation: @unchecked Sendable {
        let source: OriginalHeaderSourceRenewal
        let control: AXLogicProElements.AssignedSendMenuControl
        let footprint: [SendSlotObservation]
        let checkedBefore: OutputAssignment
        let checkedAfter: OutputAssignment
        let nonRoutingChecks: [String]
        let population: [AXUIElement]

        func permits(runtime: AXLogicProElements.Runtime, ownedPopup: AXUIElement? = nil) -> Bool {
            func protected(_ slots: [SendSlotObservation]) -> [SendSlotObservation] {
                slots.map { slot in
                    var result = slot
                    if result.ordinal == control.ordinal { result.destinationDisplay = nil }
                    return result
                }
            }
            guard source.permits(runtime: runtime, ownedPopup: ownedPopup),
                  let current = AXLogicProElements.assignedSendMenuControl(in: source.pair.strip.strip,
                    ordinal: control.ordinal, runtime: runtime.ax), control.matches(current),
                  let slots = AXLogicProElements.sendSlotObservations(in: source.pair.strip.strip, runtime: runtime.ax),
                  protected(slots) == protected(footprint),
                  let census = removalCensus(source.pair.strip, runtime: runtime), census.count == population.count,
                  zip(census, population).allSatisfy({ CFEqual($0, $1) }) else { return false }
            return source.permits(runtime: runtime, ownedPopup: ownedPopup)
        }
    }

    static func restoreChangedSendObservation(_ changed: ChangedSendObservation,
        runtime: AXLogicProElements.Runtime, timing: OutputAssignmentTiming = .live) async -> CheckedOutputReading {
        await restoreAssignedSendThroughRetainedOccupied(changed, runtime: runtime, timing: timing)
    }

    /// Immutable native handles for the source/control actually recreated by
    /// the owned inverse. Neither JSON nor a newly found singleton can recreate it.
    struct RestoredSendObservation: @unchecked Sendable {
        let source: OriginalHeaderSourceRenewal
        let control: AXLogicProElements.AssignedSendMenuControl
        let population: [AXUIElement]

        func permits(runtime: AXLogicProElements.Runtime) -> Bool {
            guard source.permits(runtime: runtime),
                  let current = AXLogicProElements.assignedSendMenuControl(in: source.pair.strip.strip,
                    ordinal: control.ordinal, runtime: runtime.ax), control.matches(current),
                  let census = removalCensus(source.pair.strip, runtime: runtime), census.count == population.count,
                  zip(census, population).allSatisfy({ CFEqual($0, $1) }) else { return false }
            return source.permits(runtime: runtime)
        }
    }

    /// Immutable native handles confined to the existing owned request's
    /// lifetime. Sendability is not action authority: every use must renew the
    /// source and exact empty control. No JSON receipt can construct this proof.
    struct RemovedSendObservation: @unchecked Sendable {
        let source: OriginalHeaderSourceRenewal
        let empty: AXLogicProElements.EmptySendMenuControl
        let before: SendSlotObservation
        let checkedDestination: OutputAssignment
        let nonRoutingChecks: [String]
        let population: [AXUIElement]

        func permits(runtime: AXLogicProElements.Runtime) -> Bool {
            guard source.permits(runtime: runtime),
                  let current = soleEmptySend(in: source.pair.strip.strip, runtime: runtime.ax),
                  empty.matches(current),
                  let currentPopulation = removalCensus(source.pair.strip, runtime: runtime),
                  currentPopulation.count == population.count,
                  zip(currentPopulation, population).allSatisfy({ CFEqual($0, $1) }) else { return false }
            return source.permits(runtime: runtime)
        }
    }

    /// Explicit internal inverse consumes a native request-local removal proof,
    /// never a freshly published reference or a caller's JSON assertion.
    static func restoreRemovedSendObservation(_ removed: RemovedSendObservation,
        runtime: AXLogicProElements.Runtime, timing: OutputAssignmentTiming = .live) async -> CheckedOutputReading {
        await restoreAssignedSendThroughRetainedEmpty(removed, runtime: runtime, timing: timing)
    }

    static func isSendRemovalTitle(_ title: String) -> Bool { ["No Send", "센드 없음"].contains(title) }
    static func soleEmptySend(in strip: AXUIElement, runtime: AXHelpers.Runtime)
        -> AXLogicProElements.EmptySendMenuControl? {
        var controls: [AXLogicProElements.EmptySendMenuControl] = []
        guard let slots = AXLogicProElements.sendSlotObservations(in: strip, runtime: runtime,
            observingEmptySlot: { controls.append($0) }), slots.count == 1,
              slots[0].state == .observedEmpty, controls.count == 1 else { return nil }
        return controls[0]
    }

    /// A complete singleton occupied→empty transition under one owned leaf.
    /// No old slot ordinal is rebound and no inverse is inferred from this receipt.
    static func finishSendRemoval(original: AXMixerStripBinding.Binding, before: [SendSlotObservation],
        checkedBefore: OutputAssignment, nonRoutingChecks: [String],
        population: [AXUIElement], extras initial: [String: Any], runtime: AXLogicProElements.Runtime)
        async -> CheckedOutputReading {
        var extras = initial
        func uncertain(_ hint: String) -> CheckedOutputReading {
            extras["hint"] = hint
            return .init(result: .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras)), assignment: nil)
        }
        guard before.count == 2, before.filter({ $0.state == .observedEmpty }).count == 1,
              before.filter({ $0.state == .occupiedUnknownDestination }).count == 1,
              let occupiedBefore = before.first(where: { $0.state == .occupiedUnknownDestination }),
              let pair = AXMixerStripBinding.outputAssociation, pair.strip.matches(original),
              let census = removalCensus(original, runtime: runtime) else {
            return uncertain("Removal has no complete singleton footprint and retained-original-header renewal authority.")
        }
        let originalCount = census.filter { CFEqual($0, original.strip) }.count
        guard originalCount <= 1, originalCount == 0 || original.currentIndex(runtime: runtime) != nil else {
            return uncertain("Removal lost unique current custody of its surviving original physical source.")
        }
        // No Send may retire the occupied controls without retiring their strip.
        // Re-observe the retained original header with the same owned inverse;
        // a surviving source must still be that exact original CF/path.
        let renewal = await renewSourceThroughOriginalHeader(pair, original: original, runtime: runtime,
            selectedHeaderRequired: false,
            sourceDisposition: originalCount == 1 ? .survivingOriginal : .retiredOriginal)
        extras["ui_effects"] = ["navigation_performed": renewal.effects.navigationPerformed,
            "attempted": renewal.effects.attempted, "changed": renewal.effects.changed,
            "restoration": renewal.effects.restoration, "reason": renewal.effects.reason as Any? ?? NSNull()]
        guard let source = renewal.source, source.permits(runtime: runtime),
              originalCount == 0 || source.pair.strip.matches(original),
              let empty = soleEmptySend(in: source.pair.strip.strip, runtime: runtime.ax) else {
            return uncertain("Removed source did not independently renew to exactly one completely observed empty send.")
        }
        let expected = population.map { CFEqual($0, original.strip) ? source.pair.strip.strip : $0 }
        guard let finalPopulation = removalCensus(original, runtime: runtime),
              finalPopulation.count == expected.count,
              zip(finalPopulation, expected).allSatisfy({ CFEqual($0, $1) }),
              let finalEmpty = soleEmptySend(in: source.pair.strip.strip, runtime: runtime.ax),
              empty.matches(finalEmpty), source.permits(runtime: runtime) else {
            return uncertain("Empty anchor, complete physical population or original source changed after removal.")
        }
        extras["after"] = ["state": "observed_empty"]
        extras["changed"] = true; extras["strip_count_after"] = finalPopulation.count
        extras["source_renewal"] = source.pair.source; extras["reference_reread_required"] = true
        extras["source_index_after"] = source.index
        extras["original_source_survived"] = originalCount == 1
        extras["verify_source"] = "ax_complete_send_census"; extras["snapshot_atomic"] = false
        let proof = RemovedSendObservation(source: source, empty: finalEmpty,
            before: occupiedBefore,
            checkedDestination: checkedBefore, nonRoutingChecks: nonRoutingChecks, population: finalPopulation)
        guard proof.permits(runtime: runtime) else {
            return uncertain("The removal proof lost its current native empty binding before publication.")
        }
        sendRemovalObserver?(proof)
        return .init(result: .success(HonestContract.encodeStateA(extras: extras)), assignment: nil,
            removedSend: proof)
    }

    private static func removalCensus(_ source: AXMixerStripBinding.Binding,
        runtime: AXLogicProElements.Runtime) -> [AXUIElement]? {
        AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: source.mixer, runtime: runtime.ax)?.strips
    }

    static func finishSendRestoration(_ removed: RemovedSendObservation, original: AXMixerStripBinding.Binding,
        population: [AXUIElement], extras initial: [String: Any], runtime: AXLogicProElements.Runtime,
        timing: OutputAssignmentTiming) async -> CheckedOutputReading {
        var extras = initial
        func uncertain(_ hint: String) -> CheckedOutputReading {
            extras["hint"] = hint
            return .init(result: .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras)), assignment: nil)
        }
        // Only this native capsule's current source/header, never a caller's
        // ordinal or destination label, supplies renewal after its one inverse leaf.
        guard removed.source.pair.strip.matches(original),
              let census = removalCensus(original, runtime: runtime),
              !census.contains(where: { CFEqual($0, original.strip) }) else {
            return uncertain("Explicit inverse has no observed original-source retirement and native renewal authority.")
        }
        let renewal = await renewSourceThroughOriginalHeader(removed.source.pair, original: original,
            runtime: runtime, selectedHeaderRequired: false)
        extras["ui_effects"] = ["navigation_performed": renewal.effects.navigationPerformed,
            "attempted": renewal.effects.attempted, "changed": renewal.effects.changed,
            "restoration": renewal.effects.restoration, "reason": renewal.effects.reason as Any? ?? NSNull()]
        guard let source = renewal.source, source.permits(runtime: runtime) else {
            return uncertain("Explicit inverse failed its exact original-header renewal or restoration.")
        }
        func restoredControl() -> AXLogicProElements.AssignedSendMenuControl? {
            var controls: [AXLogicProElements.AssignedSendMenuControl] = []
            guard let slots = AXLogicProElements.sendSlotObservations(in: source.pair.strip.strip, runtime: runtime.ax,
                observingAssignedGroup: { controls.append($0) }), slots.count == 2,
                  slots.filter({ $0.state == .observedEmpty }).count == 1, controls.count == 1,
                  let occupied = slots.first(where: { $0.state == .occupiedUnknownDestination }),
                  occupied.levelRaw == removed.before.levelRaw, occupied.bypassed == removed.before.bypassed else { return nil }
            return controls.first
        }
        guard let control = restoredControl(), source.permits(runtime: runtime) else {
            return uncertain("Restored occupancy or protected level/bypass was not independently observed; no further inverse was attempted.")
        }
        let after = await AXMixerStripBinding.$current.withValue(source.pair.strip) {
            await getOutputObservation(runtime: runtime, sendOrdinal: control.ordinal, timing: timing)
        }
        if let data = after.result.message.data(using: .utf8), let receipt = try? JSONSerialization.jsonObject(with: data) {
            extras["after_acquisition"] = receipt
        }
        let expectedPopulation = population.map { CFEqual($0, original.strip) ? source.pair.strip.strip : $0 }
        guard after.assignment == removed.checkedDestination, after.sendNonRoutingChecks == removed.nonRoutingChecks,
              let final = restoredControl(), control.matches(final),
              let finalPopulation = removalCensus(original, runtime: runtime), finalPopulation.count == expectedPopulation.count,
              zip(finalPopulation, expectedPopulation).allSatisfy({ CFEqual($0, $1) }), source.permits(runtime: runtime) else {
            return uncertain("The explicit inverse lost its checked destination, raw mode/protected state, control or complete population.")
        }
        extras["after"] = removed.checkedDestination.json
        extras["changed"] = true; extras["strip_count_after"] = finalPopulation.count
        extras["source_renewal"] = source.pair.source; extras["reference_reread_required"] = true
        extras["source_index_after"] = source.index; extras["verify_source"] = "ax_send_menu_checkmark"
        extras["snapshot_atomic"] = false
        return .init(result: .success(HonestContract.encodeStateA(extras: extras)), assignment: after.assignment,
            sendNonRoutingChecks: after.sendNonRoutingChecks,
            restoredSend: .init(source: source, control: final, population: finalPopulation))
    }
}
