import MCP
import Testing
@testable import LogicProMCP

@Suite("#291 input Saga admission")
struct Issue291InputSagaTests {
    @Test(arguments: ["valid", "reverse", "canonical_plan", "canonical_digest", "multiple", "missing_target",
                      "noop", "zero", "overflow", "boolean", "floating", "string", "extra_destination",
                      "no_replace", "extra_param", "wrong_inverse", "blank_project"])
    func onlyAnExplicitTypedSingletonCanOwnAnInputChange(_ condition: String) {
        let before = condition == "reverse" ? 256 : 1
        let after = condition == "reverse" ? 1 : 256
        var params: [String: Value] = ["destination": .object(["kind": .string("bus"), "number": .int(after)]),
            "expected_current": .object(["kind": .string("bus"), "number": .int(before)]), "replace_existing": .bool(true)]
        switch condition {
        case "noop": params["destination"] = params["expected_current"]
        case "zero", "overflow", "boolean", "floating":
            let number: Value = condition == "zero" ? .int(0) : condition == "overflow" ? .int(257)
                : condition == "boolean" ? .bool(true) : .double(2)
            params["destination"] = .object(["kind": .string("bus"), "number": number])
        case "string": params["destination"] = .string("bus:2")
        case "extra_destination": params["destination"] = .object(["kind": .string("bus"), "number": .int(2), "fallback": .bool(true)])
        case "no_replace": params["replace_existing"] = .bool(false)
        case "extra_param": params["allow_create"] = .bool(true)
        case "blank_project": params["project_ref"] = .string(" ")
        default: break
        }
        let step = SagaStep(operationID: .mixerSetInputBusVerified,
            targetRef: condition == "missing_target" ? nil : .init(rawValue: "trk_original"), params: params,
            expectedInverse: .init(operationID: condition == "wrong_inverse" ? .mixerSetOutputVerified : .mixerSetInputBusVerified,
                valueParameter: "destination"))
        var plan = SagaPlan(steps: condition == "multiple" ? [step, step] : [step], idempotencyKey: "input-admission")
        if condition == "canonical_plan" { plan.canonicalPlanID = "plan_foreign" }
        if condition == "canonical_digest" { plan.canonicalDigest = String(repeating: "a", count: 64) }
        #expect(InputBusSagaAdapter.accepts(plan) == ["valid", "reverse"].contains(condition))
    }
}
