@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("#965 one native Help sample per strip extraction", .serialized)
struct Issue965StripHelpSampleTests {
    private final class Reads: @unchecked Sendable {
        let builder: FakeAXRuntimeBuilder
        let input: AXUIElement
        let failFirstInput: Bool
        var counts: [(AXUIElement, Int)] = []
        init(builder: FakeAXRuntimeBuilder, input: AXUIElement, failFirstInput: Bool) {
            self.builder = builder; self.input = input; self.failFirstInput = failFirstInput
        }
        func read(_ element: AXUIElement) -> Result<AnyObject?, AXHelpers.AXStatusError> {
            let index = counts.firstIndex { CFEqual($0.0, element) }
            let count: Int
            if let index { counts[index].1 += 1; count = counts[index].1 }
            else { counts.append((element, 1)); count = 1 }
            if failFirstInput, CFEqual(input, element), count == 1 {
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            }
            return .success(builder.attributeValue(element, kAXHelpAttribute as String).map { $0 as AnyObject })
        }
    }

    @Test(arguments: [false, true])
    func populationClassifiersShareStatusWithoutRetryingAndNextBookendReadsAgain(failed: Bool) async throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = builder.element(1_965_880)
        let insert = builder.element(1_965_881)
        let input = builder.element(1_965_882)
        let output = builder.element(1_965_883)
        builder.setRole(strip, kAXLayoutItemRole as String)
        builder.setButton(insert, description: "Audio Plug-in", help: "Audio Plug-in", x: 0, y: 0, width: 60, height: 20)
        builder.setButton(input, description: "Input 1", help: "Input slot", x: 0, y: 30, width: 60, height: 20)
        builder.setButton(output, description: "Stereo Output", help: "Output slot", x: 0, y: 60, width: 60, height: 20)
        builder.setChildren(strip, [insert, input, output])
        let reads = Reads(builder: builder, input: input, failFirstInput: failed)
        let runtime = builder.makeLogicRuntime(attributeValueHandler: { element, attribute in
            guard attribute == kAXHelpAttribute as String else { return nil }
            return .some(try? reads.read(element).get())
        }, attributeValueResultHandler: { element, attribute in
            guard attribute == kAXHelpAttribute as String else { return nil }
            return reads.read(element)
        }, setAttributeHandler: nil, performActionHandler: nil)
        let context = OperationTraceContext(mutationGateAcquired: true)
        OperationTraceContext.$current.withValue(context) {
            let first = AccessibilityChannel.readChannelStrips(from: [strip], runtime: runtime, stoppingWhen: { false })
            #expect(first?.count == 1)
            if failed {
                #expect(first?.first?.inputObservation?.state == .unreadable,
                    "A failed physical Help sample must not heal when another classifier asks again")
            } else {
                #expect(first?.first?.input == "Input 1")
                #expect(first?.first?.output == "Stereo Output")
                #expect(first?.first?.pluginsSource == "ax")
            }
            #expect(reads.counts.allSatisfy { $0.1 == 1 }, "Each physical Help read retains its guard, but classifiers reuse its raw sample")
            let firstCounts = reads.counts
            let second = AccessibilityChannel.readChannelStrips(from: [strip], runtime: runtime, stoppingWhen: { false })
            #expect(second?.first?.input == "Input 1", "A new independent population must sample again, not retain the earlier failure")
            #expect(firstCounts.allSatisfy { old in reads.counts.first(where: { CFEqual($0.0, old.0) })?.1 == 2 })
        }
        let beforeStandalone = reads.counts.first(where: { CFEqual($0.0, input) })?.1 ?? 0
        _ = AXLogicProElements.inputSlotRead(in: strip, runtime: runtime.ax)
        #expect((reads.counts.first(where: { CFEqual($0.0, input) })?.1 ?? 0) > beforeStandalone,
            "Standalone routing/parameter consumers remain ordinary fresh reads")
    }
}
