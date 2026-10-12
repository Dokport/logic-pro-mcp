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
    func scalarOmissionKeepsDescriptionValuesAndDefaultReaderKeepsHelp(readingScalarHelp: Bool) throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = builder.element(1_965_890)
        let volume = builder.element(1_965_891)
        let pan = builder.element(1_965_892)
        let window = builder.element(1_965_893)
        let mixer = builder.element(1_965_894)
        builder.setRole(strip, kAXLayoutItemRole as String)
        for (slider, name, value) in [(volume, "Volume", 0.75), (pan, "Pan", 0.25)] {
            builder.setRole(slider, kAXSliderRole as String)
            builder.setAttribute(slider, readingScalarHelp ? kAXHelpAttribute as String : kAXDescriptionAttribute as String, name)
            builder.setAttribute(slider, kAXMinValueAttribute as String, 0.0)
            builder.setAttribute(slider, kAXMaxValueAttribute as String, 1.0)
            builder.setAttribute(slider, kAXValueAttribute as String, value)
            builder.setChildren(slider, [])
        }
        builder.setChildren(strip, [volume, pan])
        let reads = Reads(builder: builder, input: volume, failFirstInput: false)
        let runtime = builder.makeLogicRuntime(attributeValueResultHandler: { element, attribute in
            guard attribute == kAXHelpAttribute as String else { return nil }
            return reads.read(element)
        }, setAttributeHandler: nil, performActionHandler: nil)
        let states = try #require(AccessibilityChannel.readChannelStrips(from: [strip], runtime: runtime,
            window: window, mixer: mixer, readingScalarHelp: readingScalarHelp, stoppingWhen: { false }))
        #expect(states.first?.volume == 0.75)
        #expect(states.first?.pan == 0.25)
        #expect(reads.counts.isEmpty == !readingScalarHelp)
        #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
    }

    @Test(arguments: [false, true])
    func requiredSendHelpIsNotPoisonedByScalarOmission(failed: Bool) throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = builder.element(1_965_895)
        let anchor = builder.element(1_965_896)
        let knob = builder.element(1_965_897)
        builder.setRole(strip, kAXLayoutItemRole as String)
        builder.setButton(anchor, description: "Send", help: "Send slot", x: 0, y: 0, width: 60, height: 20)
        builder.setRole(knob, kAXSliderRole as String)
        builder.setAttribute(knob, kAXDescriptionAttribute as String, "Volume")
        builder.setAttribute(knob, kAXHelpAttribute as String, "Send level knob")
        builder.setAttribute(knob, kAXValueAttribute as String, 0.75)
        builder.setChildren(knob, [])
        builder.setChildren(strip, [anchor, knob])
        let reads = Reads(builder: builder, input: knob, failFirstInput: failed)
        let runtime = builder.makeLogicRuntime(attributeValueResultHandler: { element, attribute in
            guard attribute == kAXHelpAttribute as String else { return nil }
            return reads.read(element)
        }, setAttributeHandler: nil, performActionHandler: nil)
        let context = OperationTraceContext(mutationGateAcquired: true)
        let outerGuard = AXHelpers.HelpReadGuard(stop: { false })
        let outerSamples = AXHelpers.StripHelpSamples()
        try OperationTraceContext.$current.withValue(context) {
            try AXHelpers.HelpReadGuard.$current.withValue(outerGuard) {
                try AXHelpers.StripHelpSamples.$current.withValue(outerSamples) {
                    let states = try #require(AccessibilityChannel.readChannelStrips(from: [strip], runtime: runtime,
                        readingScalarHelp: false, stoppingWhen: { false }))
                    #expect(states.first?.sendSlots?.first?.state == (failed ? .unreadable : .occupiedUnknownDestination))
                    #expect(reads.counts.first(where: { CFEqual($0.0, knob) })?.1 == 1,
                        "The required send read must sample real Help exactly once, retaining its native failure")
                    #expect(AXHelpers.HelpReadGuard.current === outerGuard)
                    #expect(AXHelpers.StripHelpSamples.current === outerSamples)
                    #expect(!outerGuard.stopped)
                }
            }
        }
        #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
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
