import Foundation
import MCP

/// One confirmed occupied -∞ -> -6 dB change through the existing journal.
final class SendLevelSagaAdapter: @unchecked Sendable {
    let forward: SagaStep
    private var pair: AccessibilityChannel.HeldSelectionAssociation.Pair?
    private var effect: AccessibilityChannel.ChangedSendLevelObservation?
    private var restored: AccessibilityChannel.ChangedSendLevelObservation?
    private var attempted = false
    private var inverseConsumed = false

    static func accepts(_ plan: SagaPlan) -> Bool {
        guard plan.steps.count == 1, plan.canonicalPlanID == nil, plan.canonicalDigest == nil,
              let step = plan.steps.first, step.operationID == .mixerSetSendLevelVerified, step.targetRef != nil,
              Set(step.params.keys).subtracting(["ordinal", "level_db", "expected_current", "project_ref"]).isEmpty,
              step.params["ordinal"]?.intValue.map({ $0 >= 0 }) == true,
              step.params["level_db"] == .string("-6"), step.params["expected_current"] == .string("-∞"),
              step.expectedInverse == .init(operationID: .mixerSetSendLevelVerified, valueParameter: "level_db") else { return false }
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
        inverse["level_db"] = .string("-∞")
        return effect != nil && step.operationID == forward.operationID && step.targetRef == forward.targetRef
            && step.params == inverse && step.expectedInverse == forward.expectedInverse
    }

    private func scope<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        let parent = OperationTraceContext.current
        let limit = ContinuousClock.now.advanced(by: .seconds(
            OperationRegistry.spec(tool: "logic_mixer", command: "set_send_level_verified")!.deadline.seconds))
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
                    operation: "saga.send_level") == nil else { return nil }
            let held: AccessibilityChannel.HeldSelectionAssociation.Pair
            let ordinal: Int
            let proof = self.restored ?? self.effect
            if let proof {
                guard proof.permits(), !self.inverseConsumed || self.restored != nil else { return nil }
                held = proof.pair; ordinal = proof.snapshot.control.ordinal
            } else {
                guard !self.attempted, let reference = self.forward.targetRef,
                      let binding = await registry.resolve(reference), binding.kind == .mixerStrip,
                      let physical = binding.physicalMixerStrip,
                      let captured = await cache.retainedMixerAssociation(reference: reference, source: physical,
                        snapshot: await registry.currentSnapshot),
                      self.pair.map({ $0.strip.matches(captured.strip) && $0.track.matches(captured.track) }) ?? true,
                      let value = self.forward.params["ordinal"]?.intValue else { return nil }
                held = captured; ordinal = value
            }
            let reading = await AXMixerStripBinding.$current.withValue(held.strip) {
                await AXMixerStripBinding.$outputAssociation.withValue(held) {
                    await AccessibilityChannel.readSendBypassSnapshot(ordinal: ordinal, runtime: held.track.runtime)
                }
            }
            guard let reading, let slot = reading.slots.first(where: { $0.ordinal == ordinal }),
                  let value = slot.levelDescription.flatMap(AccessibilityChannel.sendLevelToken),
                  value == (proof?.after ?? "-∞"), held.strip.currentIndex(runtime: held.track.runtime) != nil,
                  proof.map({ $0.permits() && $0.snapshot.control.matches(reading.control)
                    && $0.snapshot.assignment == reading.assignment && $0.snapshot.checks == reading.checks
                    && $0.snapshot.slots == reading.slots }) ?? true,
                  await TargetRefResolver.validateProjectReference(self.forward.params, targetRegistry: registry,
                    operation: "saga.send_level") == nil else { return nil }
            self.pair = held
            return .init(read: .init(readSource: .axSendSlotFootprint, provenance: .liveIndependent,
                trackIndex: held.track.currentIndex(), field: "send_level_db", observed: .string(value),
                sampledAt: ISO8601DateFormatter.cacheFormatter.string(from: Date())))
        }
    }

    func run(_ step: SagaStep, router: ChannelRouter, cache: StateCache, registry: TargetRegistry) async -> StepResult {
        await scope {
            guard self.supports(step), FeatureFlags.adr002TargetRef,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Native level custody unavailable")
            }
            let response: CallTool.Result
            if let effect = self.effect {
                guard !self.inverseConsumed, effect.permits(),
                      await self.read(step, cache: cache, registry: registry) != nil else {
                    return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Owned changed level is no longer current")
                }
                self.inverseConsumed = true
                let result = await AXMixerStripBinding.$current.withValue(effect.pair.strip) {
                    await AXMixerStripBinding.$outputAssociation.withValue(effect.pair) {
                        await AccessibilityChannel.$sendLevelChangeObserver.withValue({ proof in
                            if proof.pair.strip.matches(effect.pair.strip), proof.pair.track.matches(effect.pair.track),
                               proof.before == effect.after, proof.after == effect.before,
                               proof.snapshot.assignment == effect.snapshot.assignment,
                               proof.snapshot.checks == effect.snapshot.checks {
                                self.restored = proof
                            }
                        }) {
                            await AccessibilityChannel.setSendLevelVerified(params: ["ordinal": String(effect.snapshot.control.ordinal),
                                "level_db": effect.before, "expected_current": effect.after], runtime: effect.pair.track.runtime,
                                mouse: effect.mouse, canPostEvents: effect.canPostEvents)
                        }
                    }
                }
                response = toolTextResult(result)
            } else {
                guard !self.attempted, await self.read(self.forward, cache: cache, registry: registry) != nil,
                      let held = self.pair else {
                    return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Before level source changed")
                }
                self.attempted = true
                var params = self.forward.params
                params["target_ref"] = .string(self.forward.targetRef!.rawValue)
                let upstream = AccessibilityChannel.sendLevelChangeObserver
                response = await AXMixerStripBinding.$outputAssociation.withValue(held) {
                    await AccessibilityChannel.$sendLevelChangeObserver.withValue({ proof in
                        if proof.pair.strip.matches(held.strip), proof.pair.track.matches(held.track),
                           proof.before == "-∞", proof.after == "-6" {
                            self.effect = proof; upstream?(proof)
                        }
                    }) {
                        await MixerDispatcher.handle(command: "set_send_level_verified", params: params,
                            router: router, cache: cache, targetRegistry: registry)
                    }
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
