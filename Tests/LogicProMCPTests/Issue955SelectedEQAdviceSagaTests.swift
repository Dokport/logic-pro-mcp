import CryptoKit
import Foundation
import MCP
import Testing
@testable import LogicProMCP

private actor SelectedEQSurface: Channel {
    nonisolated let id: ChannelID = .accessibility
    var frequencyRaw = 525.0
    var frequencyDisplay = "625 Hz"
    var gainRaw = 250.0
    var gainDisplay = "0.0 dB"
    var writes: [(String, String, Double)] = []
    var reads = 0
    let fault: String
    init(_ fault: String) { self.fault = fault }
    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy(detail: "injected named EQ surface") }
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        if operation == "plugin.get_channel_eq_state_verified" {
            reads += 1
            if fault == "unknown" { return .error(HonestContract.encodeV2StateC(error: .readbackUnavailable)) }
            func field(_ raw: Double, _ display: String) -> [String: Any] {
                ["observed_raw": raw, "raw_unit": "raw_ax_value", "read_status": "read",
                 "observed_display": display, "display_read_status": "read"]
            }
            let names = ["Low Cut", "Low Shelf", "Peak 1", "Peak 2", "Peak 3", "Peak 4", "High Shelf", "High Cut"]
            let bands: [[String: Any]] = names.enumerated().map { index, name in
                ["band": index + 1, "name": name,
                 "frequency": field(name == "Peak 1" ? frequencyRaw : 400, name == "Peak 1" ? frequencyDisplay : "400 Hz"),
                 "gain": field(name == "Peak 1" ? gainRaw : 250, name == "Peak 1" ? gainDisplay : "0.0 dB"),
                 "q": field(32, "0.88 "),
                 "enabled": ["observed_raw": true, "raw_unit": "boolean", "read_status": "read"]]
            }
            return .success(HonestContract.encodeV2StateA(extras: ["bands": bands, "complete": true,
                "observation_scope": "current_insert_eight_band_raw_and_host_display", "snapshot_atomic": false,
                "target_identity": ["track_index": 0, "insert": 0, "plugin_id": "logic.stock.effect.channel_eq"],
                "write_attempted": false]))
        }
        guard operation == "plugin.set_eq_band_verified",
              let parameter = params["parameter"], let unit = params["unit"],
              let value = Double(params["value"] ?? "") else {
            return .error(HonestContract.encodeV2StateC(error: .commandNotExposed))
        }
        #expect(params["expected_before"] == nil)
        #expect(params["recommendation"] == nil)
        let expected = try? #require(PluginSagaExpectedBefore.current)
        #expect(expected?.observed == .double(parameter == "frequency" ? frequencyRaw : gainRaw))
        let context = OperationTraceContext.current
        let owns: Bool
        if let context { owns = context.ownsGate() } else { owns = false }
        #expect(owns)
        let deadline = try? #require(context?.deadline)
        if let deadline { #expect(ContinuousClock.now.duration(to: deadline) <= .seconds(25)) }
        if writes.isEmpty { #expect(reads >= 3) } // Both approved before-values plus this step's fresh read.
        if parameter == "gain", fault == "second" || fault == "plateau_edit" {
            if fault == "plateau_edit" { frequencyRaw = 601 } // Same display, distinct actual owned state.
            return .error(HonestContract.encodeV2StateC(error: .axWriteFailed, extras: ["write_attempted": false]))
        }
        writes.append((parameter, unit, value))
        if parameter == "frequency" {
            frequencyRaw = unit == "raw_ax_value" ? value : 600
            frequencyDisplay = unit == "raw_ax_value" ? "625 Hz" : "800 Hz"
        } else {
            gainRaw = unit == "raw_ax_value" ? value : 220
            gainDisplay = unit == "raw_ax_value" ? "0.0 dB" : "-3.0 dB"
        }
        return .success(HonestContract.encodeV2StateA(extras: ["write_attempted": true]))
    }
    func drift(_ parameter: String) {
        if parameter == "frequency" { frequencyRaw = 526 } else { gainRaw = 251 }
    }
    func snapshot() -> (Double, Double, [(String, String, Double)], Int) { (frequencyRaw, gainRaw, writes, reads) }
}

extension VerifiedOpGateSharedTests {
@Suite(.serialized)
struct Issue955SelectedEQAdviceSagaTests {
    private struct Fixture {
        let router: ChannelRouter
        let surface: SelectedEQSurface
        let cache: StateCache
        let registry: TargetRegistry
        let journal: SagaJournal
        let wire: [String: Value]
        let plan: SagaPlan
    }
    private func fixture(_ fault: String = "") async -> Fixture {
        let registry = TargetRegistry()
        let project = TargetDescriptor.project(name: "Disposable", filePath: "/tmp/selected-eq.logicx", epoch: 0)
        _ = await registry.bind(kind: .project, descriptor: project, fingerprint: project.fingerprint)
        let descriptor = TargetDescriptor(trackIndex: 0, trackName: "Audio 1")
        let reference = await registry.bind(kind: .pluginInsert, descriptor: descriptor,
            fingerprint: TargetRefResolver.pluginInsertFingerprint(descriptor: descriptor, insert: 0,
                pluginIdentity: "logic.stock.effect.channel_eq"))
        let advice: Value = .object(["artifact_fingerprint": .string("sha256:" + String(repeating: "a", count: 64)),
            "center_hz": .double(800.25), "gain_db": .double(-3.2), "q": .double(1.4)])
        let steps: [SagaStep] = [("frequency", "Hz", 800.0, 525.0), ("gain", "dB", -3.0, 250.0)].map {
            SagaStep(operationID: .pluginsSetEQBandVerified, targetRef: reference,
                params: ["band": .string("Peak 1"), "parameter": .string($0.0), "unit": .string($0.1),
                    "value": .double($0.2), "expected_before": .double($0.3), "recommendation": advice],
                expectedInverse: .init(operationID: .pluginsSetEQBandVerified, valueParameter: "value"))
        }
        let wire: [String: Value] = ["idempotency_key": .string("selected-eq"), "steps": .array(steps.map {
            .object(["operation_id": .string($0.operationID.rawValue), "target_ref": .string(reference.rawValue),
                "params": .object($0.params), "expected_inverse": .object([
                    "operation_id": .string($0.operationID.rawValue), "value_parameter": .string("value")])])
        })]
        let surface = SelectedEQSurface(fault); let router = ChannelRouter(); await router.register(surface)
        let cache = StateCache(); await cache.updateTracks([TrackState(id: 0, name: "Audio 1", type: .audio)])
        return Fixture(router: router, surface: surface, cache: cache, registry: registry, journal: SagaJournal(),
            wire: wire, plan: .init(steps: steps, idempotencyKey: "selected-eq"))
    }
    private func confirmed(_ f: Fixture) throws -> [String: Value] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let hash = SHA256.hash(data: try encoder.encode(f.plan)).map { String(format: "%02x", $0) }.joined()
        return f.wire.merging(["confirmed_plan_hash": .string(hash)]) { _, new in new }
    }
    private func run(_ f: Fixture, params: [String: Value], command: String = "saga_execute") async throws -> [String: Any] {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await FeatureFlags.withAdr002TargetRefForTests(true) {
                let result = await SystemDispatcher.handle(command: command, params: params,
                    router: f.router, cache: f.cache, targetRegistry: f.registry, dialogPresent: { false },
                    sagaJournal: f.journal, mutationGate: LogicMutationGate(), sagaRefreshAfterWrite: {},
                    sagaLiveReadback: .unavailable)
                return try #require(decodedJSONObject(sharedToolText(result)))
            }
        }
    }

    @Test func selectedAdviceUsesHostUnitsAndKeepsActualRawReadback() async throws {
        let f = await fixture()
        let before = await f.surface.snapshot()
        #expect(before.0 == 525 && before.1 == 250 && before.2.isEmpty)
        let preflight = try await run(f, params: f.wire, command: "saga_preflight")
        let ok = try #require(preflight["ok"] as? Bool)
        #expect(ok)
        let result = try await run(f, params: confirmed(f))
        let after = await f.surface.snapshot()
        #expect(after.2.count == 2)
        #expect(after.0 == 600 && after.1 == 220)
        #expect(after.3 >= 4)
        #expect(result["saga_state"] as? String == "completed")
        let steps = try #require(result["steps"] as? [[String: Any]])
        #expect(steps.count == 2)
        let evidence = try #require(steps.first?["evidence"] as? [String: Any])
        let beforeState = try #require(evidence["before_state"] as? [String: Any])
        #expect(JSONInspector.number(of: beforeState["value"]) == 525)
    }

    @Test(arguments: ["second", "plateau_edit"])
    func selectedEQFailureUsesRawInverseAndNeverOwnsADisplayPlateau(_ fault: String) async throws {
        let f = await fixture(fault)
        let result = try await run(f, params: confirmed(f))
        let after = await f.surface.snapshot()
        if fault == "second" {
            #expect(after.2.count == 2)
            #expect(after.2.last?.0 == "frequency")
            #expect(after.2.last?.1 == "raw_ax_value")
            #expect(after.2.last?.2 == 525)
            #expect(after.0 == 525 && after.1 == 250)
            #expect(result["saga_state"] as? String == "fullyCompensated")
        } else {
            #expect(after.2.count == 1)
            #expect(after.0 == 601 && after.1 == 250)
            #expect(result["saga_state"] as? String == "rollbackUncertain")
        }
    }

    @Test(arguments: ["missing", "wrong", "later_invalid", "frequency", "gain", "unknown"])
    func selectedEQInvalidLaterOrStaleApprovalIsEntirelyWriteFree(_ fault: String) async throws {
        let f = await fixture(fault)
        var params = try confirmed(f)
        if fault == "missing" { params.removeValue(forKey: "confirmed_plan_hash") }
        if fault == "wrong" { params["confirmed_plan_hash"] = .string("wrong") }
        if fault == "later_invalid", var steps = params["steps"]?.arrayValue,
           var step = steps[1].objectValue, var fields = step["params"]?.objectValue {
            fields["unit"] = .string("Hz"); step["params"] = .object(fields); steps[1] = .object(step)
            params["steps"] = .array(steps)
            let original = f.plan.steps[1]
            let invalid = SagaStep(operationID: original.operationID, targetRef: original.targetRef,
                params: fields, expectedInverse: original.expectedInverse)
            let plan = SagaPlan(steps: [f.plan.steps[0], invalid], idempotencyKey: f.plan.idempotencyKey)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let hash = SHA256.hash(data: try encoder.encode(plan)).map { String(format: "%02x", $0) }.joined()
            params["confirmed_plan_hash"] = .string(hash) // Refusal must come from validation, not stale consent.
        }
        if fault == "frequency" || fault == "gain" { await f.surface.drift(fault) }
        let result = try await run(f, params: params)
        let after = await f.surface.snapshot()
        #expect(after.2.isEmpty)
        #expect(result["state"] as? String == "C")
    }

    @Test func originalAdviceAndApprovedTargetsAreDistinctCanonicalContent() async throws {
        let f = await fixture()
        let preflight = try await run(f, params: f.wire, command: "saga_preflight")
        let firstHash = try #require(preflight["plan_hash"] as? String)
        var changed = f.wire
        var steps = try #require(changed["steps"]?.arrayValue)
        for index in steps.indices {
            var step = try #require(steps[index].objectValue)
            var fields = try #require(step["params"]?.objectValue)
            var advice = try #require(fields["recommendation"]?.objectValue)
            advice["center_hz"] = .double(801.25); fields["recommendation"] = .object(advice)
            step["params"] = .object(fields); steps[index] = .object(step)
        }
        changed["steps"] = .array(steps)
        let other = try await run(f, params: changed, command: "saga_preflight")
        let otherHash = try #require(other["plan_hash"] as? String)
        #expect(firstHash != otherHash)
        changed["confirmed_plan_hash"] = .string(firstHash)
        let refused = try await run(f, params: changed)
        #expect(refused["state"] as? String == "C")
        let state = await f.surface.snapshot(); #expect(state.2.isEmpty)
    }
}
}
