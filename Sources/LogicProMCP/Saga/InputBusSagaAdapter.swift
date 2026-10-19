import Foundation
import MCP

/// One confirmed Bus-to-Bus input change on the scalar writer's checked physical sink.
final class InputBusSagaAdapter: @unchecked Sendable {
    let forward: SagaStep
    private var pair: AccessibilityChannel.HeldSelectionAssociation.Pair?
    private var readControl: AXMixerInputSlotBinding?
    private var readRenewal: AccessibilityChannel.OriginalHeaderSourceRenewal?
    private var effect: AccessibilityChannel.ChangedInputObservation?
    private var restored: AccessibilityChannel.ChangedInputObservation?
    private var attempted = false
    private var inverseConsumed = false

    static func bus(_ value: Value?) -> Int? {
        guard let object = value?.objectValue, Set(object.keys) == ["kind", "number"],
              object["kind"] == .string("bus"), let number = object["number"]?.intValue,
              (1...256).contains(number) else { return nil }
        return number
    }

    static func accepts(_ plan: SagaPlan) -> Bool {
        guard plan.steps.count == 1, plan.canonicalPlanID == nil, plan.canonicalDigest == nil,
              let step = plan.steps.first, step.operationID == .mixerSetInputBusVerified, step.targetRef != nil,
              Set(step.params.keys).subtracting(["destination", "expected_current", "replace_existing", "project_ref"]).isEmpty,
              let before = bus(step.params["expected_current"]), let after = bus(step.params["destination"]), before != after,
              step.params["replace_existing"] == .bool(true),
              step.expectedInverse == .init(operationID: .mixerSetInputBusVerified, valueParameter: "destination") else { return false }
        if let project = step.params["project_ref"] {
            guard let value = project.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        }
        return true
    }

    init?(plan: SagaPlan) {
        guard Self.accepts(plan), let forward = plan.steps.first else { return nil }
        self.forward = forward
    }

    func supports(_ step: SagaStep) -> Bool {
        if step == forward { return true }
        var inverse = forward.params
        inverse["destination"] = Self.bus(forward.params["expected_current"]).map { .string("bus:\($0)") }
        return effect != nil && step.operationID == forward.operationID && step.targetRef == forward.targetRef
            && step.params == inverse && step.expectedInverse == forward.expectedInverse
    }

    static func journalValue(_ step: SagaStep) -> Value? {
        bus(step.params["destination"]).map { .string("bus:\($0)") }
    }

    private func beforeStillCurrent() -> Bool {
        guard let pair, let readControl,
              pair.track.currentIndex() != nil, pair.strip.currentIndex(runtime: pair.track.runtime) != nil,
              readRenewal.map({ $0.pair.strip.matches(pair.strip) && $0.pair.track.matches(pair.track)
                && $0.permits(runtime: pair.track.runtime) }) ?? true else { return false }
        let input = AXLogicProElements.inputSlotRead(in: pair.strip.strip, runtime: pair.track.runtime.ax)
        guard case .source(let label) = input.reading, let control = input.control else { return false }
        return readControl.matches(.init(owner: pair.strip, control: control, source: label))
    }

    private func scope<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        let parent = OperationTraceContext.current
        let limit = ContinuousClock.now.advanced(by: .seconds(
            OperationRegistry.spec(tool: "logic_mixer", command: "set_input_bus_verified")!.deadline.seconds))
        let child = OperationTraceContext(parentTraceID: parent?.traceID,
            mutationGateAcquired: parent?.mutationGateAcquired ?? false, ownsGate: { parent?.ownsGate() ?? false },
            deadline: min(parent?.deadline ?? limit, limit),
            cancellationRequested: { Task.isCancelled || parent?.cancellationRequested() == true })
        return await OperationTraceContext.$current.withValue(child) { await body() }
    }

    func read(_ step: SagaStep, cache: StateCache, registry: TargetRegistry) async -> ObservedState? {
        await scope {
            guard FeatureFlags.adr002TargetRef, self.supports(step),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  await TargetRefResolver.validateProjectReference(self.forward.params, targetRegistry: registry,
                    operation: "saga.input_bus") == nil else { return nil }
            let held: AccessibilityChannel.HeldSelectionAssociation.Pair
            let proof = self.restored ?? self.effect
            if let proof {
                guard !self.inverseConsumed || self.restored != nil,
                      let reading = proof.retainedCheckedRead(), case .bus(let actual)? = reading.assignment,
                      await TargetRefResolver.validateProjectReference(self.forward.params, targetRegistry: registry,
                        operation: "saga.input_bus") == nil else { return nil }
                return .init(read: .init(readSource: .axInputMenuCheckmark, provenance: .liveIndependent,
                    trackIndex: proof.current.track.currentIndex(), field: "input_bus", observed: .string("bus:\(actual)"),
                    sampledAt: proof.sampledAt))
            } else if let captured = self.pair {
                guard !self.attempted, self.beforeStillCurrent() else { return nil }
                held = captured
            } else {
                guard !self.attempted, let reference = self.forward.targetRef,
                      let binding = await registry.resolve(reference) else { return nil }
                let captured: AccessibilityChannel.HeldSelectionAssociation.Pair
                if binding.kind == .mixerStrip, let physical = binding.physicalMixerStrip,
                   let candidate = await cache.retainedMixerAssociation(reference: reference, source: physical,
                    snapshot: await registry.currentSnapshot) {
                    // An initially stale physical reference is never adopted or rebound.
                    guard physical.currentIndex(runtime: candidate.track.runtime) != nil else { return nil }
                    captured = candidate
                } else if binding.kind == .track, let track = binding.physicalTrack,
                          let candidate = await cache.retainedTrackMixerAssociation(reference: reference, track: track,
                            snapshot: await registry.currentSnapshot), track.currentIndex() != nil {
                    captured = candidate
                } else { return nil }
                if captured.strip.currentIndex(runtime: captured.track.runtime) == nil {
                    // A Track intent addresses this exact original header, not the retired mix_ ref.
                    let renewal = await AccessibilityChannel.renewSourceThroughOriginalHeader(captured,
                        original: captured.strip, runtime: captured.track.runtime)
                    guard let source = renewal.source, source.permits(runtime: captured.track.runtime) else {
                        Log.info("Input Saga source renewal unavailable: restoration=\(renewal.effects.restoration),reason=\(renewal.effects.reason ?? "none")", subsystem: "saga")
                        return nil
                    }
                    held = source.pair; self.readRenewal = source
                } else { held = captured }
            }
            let reading = await AXMixerStripBinding.$current.withValue(held.strip) {
                await AXMixerStripBinding.$outputAssociation.withValue(held) {
                    await AccessibilityChannel.getInputBusObservation(runtime: held.track.runtime)
                }
            }
            let current = reading.inputRenewal?.pair ?? held
            let receipt = decodedJSONObject(reading.result.message)
            guard reading.result.isSuccess, let receipt,
                  receipt["state"] as? String == "A", receipt["popup_menu_state"] as? String == "closed",
                  case .bus(let actual)? = reading.assignment,
                  actual == Self.bus(self.forward.params["expected_current"]),
                  let control = reading.inputSlot, control.owner.matches(current.strip),
                  current.track.matches(held.track), current.track.currentIndex() != nil,
                  current.strip.currentIndex(runtime: held.track.runtime) != nil,
                  reading.inputRenewal.map({ $0.original.matches(held.strip) && $0.originalTrack.matches(held.track)
                    && $0.permits(runtime: held.track.runtime) }) ?? current.strip.matches(held.strip),
                  await TargetRefResolver.validateProjectReference(self.forward.params, targetRegistry: registry,
                    operation: "saga.input_bus") == nil else {
                // Only existing bounded status fields, never project/target data.
                let effects = receipt?["ui_effects"] as? [String: Any]
                let status = ["state", "error", "popup_menu_state", "focus_restoration", "source_custody_after_cleanup"]
                    .map { "\($0)=\(receipt?[$0].map(String.init(describing:)) ?? "unavailable")" }.joined(separator: ",")
                Log.info("Input Saga before-state unavailable: \(status),restoration=\(effects?["restoration"] as? String ?? "unavailable"),reason=\(effects?["reason"] as? String ?? "none")", subsystem: "saga")
                return nil
            }
            self.pair = current; self.readControl = control
            self.readRenewal = reading.inputRenewal ?? self.readRenewal
            return .init(read: .init(readSource: .axInputMenuCheckmark, provenance: .liveIndependent,
                trackIndex: current.track.currentIndex(), field: "input_bus",
                observed: .string("bus:\(actual)"),
                sampledAt: ISO8601DateFormatter.cacheFormatter.string(from: Date())))
        }
    }

    func run(_ step: SagaStep, router: ChannelRouter, cache: StateCache, registry: TargetRegistry) async -> StepResult {
        await scope {
            guard self.supports(step), FeatureFlags.adr002TargetRef,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Native input custody unavailable")
            }
            let response: CallTool.Result
            if let effect = self.effect {
                guard !self.inverseConsumed, case .bus(let originalBus) = effect.before, effect.creation == nil, effect.permits(),
                      await TargetRefResolver.validateProjectReference(self.forward.params, targetRegistry: registry,
                        operation: "saga.input_bus") == nil else {
                    return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Owned changed input is no longer current")
                }
                self.inverseConsumed = true
                let result = await AXMixerStripBinding.$current.withValue(effect.current.strip) {
                    await AXMixerStripBinding.$outputAssociation.withValue(effect.current) {
                        await AccessibilityChannel.$inputChangeObserver.withValue({ proof in
                            if proof.original.strip.matches(effect.current.strip), proof.original.track.matches(effect.current.track),
                               proof.before == .bus(effect.after), proof.after == originalBus, proof.sink == effect.sink {
                                self.restored = proof
                            }
                        }) {
                            await AccessibilityChannel.setInputBusVerified(params: ["destination": "bus:\(originalBus)",
                                "expected_current": "bus:\(effect.after)", "replace_existing": "true"],
                                runtime: effect.current.track.runtime, ownedInverse: effect)
                        }
                    }
                }
                response = toolTextResult(result)
            } else {
                guard !self.attempted, self.beforeStillCurrent(), let held = self.pair,
                      await TargetRefResolver.validateProjectReference(self.forward.params, targetRegistry: registry,
                        operation: "saga.input_bus") == nil else {
                    return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Before input source changed")
                }
                self.attempted = true
                let upstream = AccessibilityChannel.inputChangeObserver
                let traceID = await MixerDispatcher.startTraceIfEnabled(command: "set_input_bus_verified")
                response = await AccessibilityChannel.$inputChangeObserver.withValue({ proof in
                    if proof.original.strip.matches(held.strip), proof.original.track.matches(held.track),
                       proof.before == Self.bus(self.forward.params["expected_current"]).map(InputAssignment.bus),
                       proof.creation == nil, proof.after == Self.bus(self.forward.params["destination"]) {
                        self.effect = proof; upstream?(proof)
                    }
                }) {
                    let result = await MixerDispatcher.withWriteBoundaryArmed(traceID) {
                        await AXMixerStripBinding.$current.withValue(held.strip) {
                            await AXMixerStripBinding.$outputAssociation.withValue(held) {
                                await router.route(operation: "mixer.set_input_bus_verified", params: [
                                    "destination": "bus:\(Self.bus(self.forward.params["destination"])!)",
                                    "expected_current": "bus:\(Self.bus(self.forward.params["expected_current"])!)", "replace_existing": "true"])
                            }
                        }
                    }
                    return await MixerDispatcher.finalizeTrace(toolTextResult(result), traceID: traceID)
                }
            }
            let mapped = ProductionSagaStepExecutor.mapResponse(response, operationID: step.operationID)
            if case .text(let text, _, _) = response.content.first,
               let body = decodedJSONObject(text), let attempted = body["write_attempted"] as? Bool {
                return .init(state: mapped.state, writeBoundaryCrossed: attempted, detail: mapped.detail)
            }
            return mapped
        }
    }
}
