import MCP
import Testing
@testable import LogicProMCP

struct SendSagaWireCompatibilityTests {
    private func replacement(before: Value, after: Value) -> SagaPlan {
        .init(steps: [.init(operationID: .mixerSetSendOutputVerified,
            targetRef: .init(rawValue: "mix_bus_replacement"), params: ["ordinal": .int(1),
                "destination": after, "expected_current": before, "replace_existing": .bool(true)],
            expectedInverse: .init(operationID: .mixerSetSendOutputVerified, valueParameter: "destination"))],
            idempotencyKey: "bus-replacement-wire")
    }

    @Test(arguments: [(1, 2), (2, 1), (1, 256), (256, 1)])
    func distinctExistingBusSendChangesUseTheNativeCapsulePair(before: Int, after: Int) throws {
        #expect(AccessibilityChannel.supportsOccupiedSendChange(before: .bus(before), after: .bus(after)))
        let plan = replacement(before: .object(["kind": .string("bus"), "number": .int(before)]),
            after: .object(["kind": .string("bus"), "number": .int(after)]))
        #expect(SendRemovalSagaAdapter.accepts(plan))
        #expect(SendRemovalSagaAdapter.journalValue(try #require(plan.steps.first)) == .string("bus:\(after)"))
        var unowned = plan
        unowned.canonicalPlanID = "unowned"; unowned.canonicalDigest = "unowned"
        #expect(!SendRemovalSagaAdapter.accepts(unowned))
    }

    @Test func existingBusReplacementKeepsBothWireValuesAndFiniteDirectionsStrict() {
        let bus: (Value) -> Value = { .object(["kind": .string("bus"), "number": $0]) }
        for invalid: Value in [.double(1), .double(1.5), .bool(true), .string("1"), .null, .int(0), .int(257)] {
            #expect(!SendRemovalSagaAdapter.accepts(replacement(before: bus(invalid), after: bus(.int(2)))))
            #expect(!SendRemovalSagaAdapter.accepts(replacement(before: bus(.int(2)), after: bus(invalid))))
        }
        #expect(!AccessibilityChannel.supportsOccupiedSendChange(before: .bus(1), after: .bus(1)))
        #expect(!SendRemovalSagaAdapter.accepts(replacement(before: bus(.int(1)), after: bus(.int(1)))))
        for unsupported: OutputAssignment in [.stereoOutput, .physical(3, 4), .noOutput] {
            #expect(!AccessibilityChannel.supportsOccupiedSendChange(before: .bus(1), after: unsupported))
        }
    }

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
