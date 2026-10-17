import MCP
import Testing
@testable import LogicProMCP

struct SendSagaWireCompatibilityTests {
    @Test func existingBusDestinationStillRequiresAnIntegerWireValue() {
        func plan(_ number: Value) -> SagaPlan {
            .init(steps: [.init(operationID: .mixerSetSendOutputVerified,
                targetRef: .init(rawValue: "mix_bus_wire"), params: ["ordinal": .int(1),
                    "destination": .object(["kind": .string("bus"), "number": number]),
                    "expected_current": .object(["kind": .string("stereo_output")]),
                    "replace_existing": .bool(true)],
                expectedInverse: .init(operationID: .mixerSetSendOutputVerified, valueParameter: "destination"))],
                idempotencyKey: "bus-wire-compatibility")
        }
        #expect(SendRemovalSagaAdapter.accepts(plan(.int(1))))
        for invalid: Value in [.double(1), .double(1.5), .bool(true), .string("1"), .null] {
            #expect(!SendRemovalSagaAdapter.accepts(plan(invalid)))
        }
    }
}
