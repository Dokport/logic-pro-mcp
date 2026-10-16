import Foundation
import MCP

/// One confirmed occupied Post Fader -> Pre Fader or Post Pan change, with a native owned inverse.
/// This does not interpret a census ordinal as a physical screen-slot number.
final class SendModeSagaAdapter: @unchecked Sendable {
    let forward: SagaStep
    private var pair: AccessibilityChannel.HeldSelectionAssociation.Pair?
    private var effect: AccessibilityChannel.ChangedSendModeObservation?
    private var restored: AccessibilityChannel.ChangedSendModeObservation?
    private var attempted = false
    private var inverseConsumed = false

    static func accepts(_ plan: SagaPlan) -> Bool {
        guard plan.steps.count == 1, plan.canonicalPlanID == nil, plan.canonicalDigest == nil,
              let step = plan.steps.first, step.operationID == .mixerSetSendModeVerified, step.targetRef != nil,
              Set(step.params.keys).subtracting(["ordinal", "mode", "expected_current", "project_ref"]).isEmpty,
              step.params["ordinal"]?.intValue.map({ $0 >= 0 }) == true,
              step.params["mode"] == .string("pre_fader") || step.params["mode"] == .string("post_pan"),
              step.params["expected_current"] == .string("post_fader"),
              step.expectedInverse == .init(operationID: .mixerSetSendModeVerified, valueParameter: "mode") else { return false }
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
        inverse["mode"] = .string("post_fader")
        return effect != nil && step.operationID == forward.operationID && step.targetRef == forward.targetRef
            && step.params == inverse && step.expectedInverse == forward.expectedInverse
    }

    private func scope<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        let parent = OperationTraceContext.current
        let limit = ContinuousClock.now.advanced(by: .seconds(
            OperationRegistry.spec(tool: "logic_mixer", command: "set_send_mode_verified")!.deadline.seconds))
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
                    operation: "saga.send_mode") == nil else { return nil }
            let held: AccessibilityChannel.HeldSelectionAssociation.Pair
            let ordinal: Int
            let expected: AccessibilityChannel.SendModeState?
            let proof = self.restored ?? self.effect
            if let proof {
                guard proof.permits(runtime: proof.current.track.runtime),
                      !self.inverseConsumed || self.restored != nil else { return nil }
                held = proof.current; ordinal = proof.control.ordinal; expected = proof.after
            } else {
                guard !self.attempted, let reference = self.forward.targetRef,
                      let binding = await registry.resolve(reference), binding.kind == .mixerStrip,
                      let physical = binding.physicalMixerStrip,
                      let captured = await cache.retainedMixerAssociation(reference: reference, source: physical,
                        snapshot: await registry.currentSnapshot),
                      self.pair.map({ $0.strip.matches(captured.strip) && $0.track.matches(captured.track) }) ?? true,
                      let value = self.forward.params["ordinal"]?.intValue else { return nil }
                held = captured; ordinal = value; expected = nil
            }
            let reading = await AXMixerStripBinding.$current.withValue(held.strip) {
                await AXMixerStripBinding.$outputAssociation.withValue(held) {
                    await AccessibilityChannel.getOutputObservation(runtime: held.track.runtime,
                        sendOrdinal: ordinal, observingSendMode: true)
                }
            }
            guard let mode = reading.sendMode, let destination = reading.assignment, destination != .noOutput,
                  expected.map({ mode == $0 && destination == proof?.checkedDestination }) ?? (mode.mode == .postFader),
                  held.strip.currentIndex(runtime: held.track.runtime) != nil,
                  proof.map({ $0.permits(runtime: held.track.runtime) }) ?? true,
                  await TargetRefResolver.validateProjectReference(self.forward.params, targetRegistry: registry,
                    operation: "saga.send_mode") == nil else { return nil }
            self.pair = held
            return .init(read: .init(readSource: .axSendMenuCheckmark, provenance: .liveIndependent,
                trackIndex: held.track.currentIndex(), field: "send_mode", observed: .string(mode.mode.rawValue),
                sampledAt: ISO8601DateFormatter.cacheFormatter.string(from: Date())))
        }
    }

    func run(_ step: SagaStep, router: ChannelRouter, cache: StateCache, registry: TargetRegistry) async -> StepResult {
        await scope {
            guard self.supports(step), FeatureFlags.adr002TargetRef,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Native mode custody unavailable")
            }
            let response: CallTool.Result
            if let effect = self.effect {
                guard !self.inverseConsumed, effect.permits(runtime: effect.current.track.runtime),
                      await self.read(step, cache: cache, registry: registry) != nil else {
                    return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Owned changed mode is no longer current")
                }
                self.inverseConsumed = true
                let result = await AXMixerStripBinding.$current.withValue(effect.current.strip) {
                    await AXMixerStripBinding.$outputAssociation.withValue(effect.current) {
                        await AccessibilityChannel.$sendModeChangeObserver.withValue({ proof in
                            if proof.original.strip.matches(effect.current.strip),
                               proof.original.track.matches(effect.current.track), proof.before == effect.after,
                               proof.after == effect.before, proof.checkedDestination == effect.checkedDestination {
                                self.restored = proof
                            }
                        }) {
                            await AccessibilityChannel.setSendModeVerified(params: ["ordinal": String(effect.control.ordinal),
                                "mode": effect.before.mode.rawValue, "expected_current": effect.after.mode.rawValue],
                                runtime: effect.current.track.runtime)
                        }
                    }
                }
                response = toolTextResult(result)
            } else {
                guard !self.attempted, await self.read(self.forward, cache: cache, registry: registry) != nil,
                      let held = self.pair else {
                    return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Before mode source changed")
                }
                self.attempted = true
                var params = self.forward.params
                params["target_ref"] = .string(self.forward.targetRef!.rawValue)
                let upstream = AccessibilityChannel.sendModeChangeObserver
                response = await AccessibilityChannel.$sendModeChangeObserver.withValue({ proof in
                    if proof.original.strip.matches(held.strip), proof.original.track.matches(held.track),
                       proof.before.mode == .postFader, proof.after.mode.rawValue == self.forward.params["mode"]?.stringValue {
                        self.effect = proof; upstream?(proof)
                    }
                }) {
                    await MixerDispatcher.handle(command: "set_send_mode_verified", params: params,
                        router: router, cache: cache, targetRegistry: registry)
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
