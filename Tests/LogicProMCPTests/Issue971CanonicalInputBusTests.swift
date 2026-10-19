import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("Reference-bound canonical Bus-input intent")
struct Issue971CanonicalInputBusTests {
    private func policy(_ inputs: Value? = nil, mixerOrigin: Bool = false) -> [String: Value] {
        var result: [String: Value] = [
            "schema": .string(ProjectSessionAudit.intentPolicySchema),
            "project_ref": .string("prj_00000000-0000-0000-0000-000000000001"),
            "targets": .array([.object([
                "handle": .string("source"),
                mixerOrigin ? "mixer_ref" : "track_ref": .string(
                    mixerOrigin ? "mix_00000000-0000-0000-0000-000000000002"
                        : "trk_00000000-0000-0000-0000-000000000002")
            ])])
        ]
        result["inputs"] = inputs
        return result
    }

    private func unboundCapture() -> SessionPopulationObservation.Capture {
        let now = Date()
        let boundary = StateCache.CaptureBoundary(versions: [:], occlusionRevision: 0,
            hasDocument: true, axOccluded: false)
        let project = TargetReference(rawValue: "prj_00000000-0000-0000-0000-000000000001")
        let track = TargetReference(rawValue: "trk_00000000-0000-0000-0000-000000000002")
        return .init(before: boundary, after: boundary, projectEpoch: 1,
            project: ProjectInfo(name: "Input fixture", filePath: "/tmp/input-fixture.logicx"),
            tracks: [.init(id: 0, name: "Source", type: .audio)], tracksFetchedAt: now,
            channelStrips: [], mixerFetchedAt: now, fileTrackCount: 1,
            projectFileNotBound: false, requestedProjectMatches: true, referencesEnabled: true,
            targetSnapshot: .init(projectEpoch: 1, topologyGeneration: 0),
            issued: .init(byRow: [track], byTrackIndex: [0: track], ambiguousTrackIndices: []),
            projectIssuance: .issued(project), beganAt: now, endedAt: now)
    }

    @Test
    func anUnobservedInputRemainsInTheAssessment() throws {
        let raw = policy(.array([.object(["target": .string("source"), "bus": .int(2)])]))
        guard case .accepted(let parsed) = ProjectSessionAudit.parseIntentPolicy(raw) else {
            Issue.record("The explicit input intent must parse"); return
        }
        let capture = unboundCapture()
        let assessment = ProjectSessionAudit.assessIntent(policy: parsed, capture: capture,
            graph: SessionPopulationObservation.routingGraph(capture: capture))
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(assessment)) as? [String: Any])
        let findings = try #require(body["input_findings"] as? [[String: Any]])
        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        #expect(finding["status"] as? String == "unverified")
        #expect(finding["observed"] == nil || finding["observed"] is NSNull)
        #expect((finding["expected"] as? [String: Any])?["bus"] as? Int == 2)
    }

    @Test
    func anUnobservedInputCannotDisappearFromTheCanonicalPreview() throws {
        let raw = policy(.array([.object(["target": .string("source"), "bus": .int(2)])]))
        guard case .accepted(let parsed) = ProjectSessionAudit.parseIntentPolicy(raw) else {
            Issue.record("The explicit input intent must parse"); return
        }
        let plan = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: parsed, policyValue: .object(raw),
            names: [], capture: unboundCapture(), request: .init(), snapshotCurrent: true)
        let body = try #require(sharedJSONObject(plan.json))
        let executable = try #require(body["executable"] as? Bool)
        #expect(!executable)
        let steps = try #require(body["steps"] as? [[String: Any]])
        let input = try #require(steps.first { $0["kind"] as? String == "input_assignment" })
        #expect(input["target_ref"] as? String == "trk_00000000-0000-0000-0000-000000000002")
        #expect((input["after"] as? [String: Any])?["number"] as? Int == 2)
        #expect(!(try #require(input["blocked_reasons"] as? [String])).isEmpty)
    }

    @Test(arguments: [1, 256])
    func explicitInputIsAcceptedAndRetained(bus: Int) {
        let parsed = ProjectSessionAudit.parseIntentPolicy(policy(.array([
            .object(["target": .string("source"), "bus": .int(bus)])
        ])))
        guard case .accepted = parsed else {
            Issue.record("An explicit supported Bus-input intent must parse: \(parsed)")
            return
        }
        let withoutInput = ProjectSessionAudit.parseIntentPolicy(policy())
        #expect(parsed != withoutInput)
    }

    @Test
    func differentApprovedInputsRemainDifferentPolicies() {
        let first = ProjectSessionAudit.parseIntentPolicy(policy(.array([
            .object(["target": .string("source"), "bus": .int(1)])
        ])))
        let second = ProjectSessionAudit.parseIntentPolicy(policy(.array([
            .object(["target": .string("source"), "bus": .int(2)])
        ])))
        guard case .accepted = first, case .accepted = second else {
            Issue.record("Both distinct explicit input intents must parse")
            return
        }
        #expect(first != second)
    }

    @Test(arguments: ["null", "object", "missing_target", "foreign_target", "missing_bus",
        "string_bus", "bool_bus", "zero", "too_large", "unknown_field", "duplicate", "mixer_origin"])
    func malformedOrAmbiguousInputIsRejected(mode: String) {
        var input: [String: Value] = ["target": .string("source"), "bus": .int(2)]
        switch mode {
        case "missing_target": input.removeValue(forKey: "target")
        case "foreign_target": input["target"] = .string("other")
        case "missing_bus": input.removeValue(forKey: "bus")
        case "string_bus": input["bus"] = .string("2")
        case "bool_bus": input["bus"] = .bool(true)
        case "zero": input["bus"] = .int(0)
        case "too_large": input["bus"] = .int(257)
        case "unknown_field": input["allow_create_aux"] = .bool(true)
        default: break
        }
        let value: Value = mode == "null" ? .null : mode == "object" ? .object(input)
            : .array(mode == "duplicate" ? [.object(input), .object(input)] : [.object(input)])
        let parsed = ProjectSessionAudit.parseIntentPolicy(policy(value, mixerOrigin: mode == "mixer_origin"))
        guard case .rejected = parsed else {
            Issue.record("Malformed or ambiguous input intent was accepted: \(mode)")
            return
        }
    }
}
