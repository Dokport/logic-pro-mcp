@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("#965 one native Help sample per strip extraction", .serialized)
struct Issue965StripHelpSampleTests {
    @Test("positive insert-control metadata avoids only redundant Help and remains fresh",
          arguments: ["legacy", "noted", "help_only", "unmatched", "cutoff", "fresh"])
    func positiveInsertControlMetadataDoesNotNeedHelp(mode: String) throws {
        final class Calls: @unchecked Sendable { var help = 0, guards = 0 }
        let builder = FakeAXRuntimeBuilder(), calls = Calls()
        let group = builder.element(1_971_995), bypass = builder.element(1_971_996)
        let open = builder.element(1_971_997)
        builder.setRole(group, kAXGroupRole as String)
        builder.setRole(bypass, kAXCheckBoxRole as String)
        builder.setRole(open, kAXButtonRole as String)
        builder.setChildren(group, [bypass, open])
        builder.setChildren(bypass, []); builder.setChildren(open, [])
        let metadataPositive = ["legacy", "noted", "fresh"].contains(mode)
        for (element, label) in [(bypass, "Bypass"), (open, "Open")] {
            builder.setAttribute(element, kAXDescriptionAttribute as String, metadataPositive ? label : "Unclassified control")
            builder.setAttribute(element, kAXHelpAttribute as String, mode == "unmatched" ? "Unrelated Help" : label)
        }
        let base = builder.makeAXRuntime()
        let native: @Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError> = { element, attribute in
            if attribute == kAXHelpAttribute as String { calls.help += 1 }
            return base.attributeValueResult?(element, attribute) ?? .success(base.attributeValue(element, attribute))
        }
        let raw = AXHelpers.Runtime(axApp: base.axApp,
            attributeValue: { element, attribute in try? native(element, attribute).get() },
            setAttributeValue: base.setAttributeValue,
            children: base.children, performAction: base.performAction, childCount: base.childCount,
            childrenResult: base.childrenResult,
            attributeValueResult: native)
        let failures = AXPluginInstanceIdentity.FailedReads()
        let runtime = mode == "noted" ? AXPluginInstanceIdentity.noting(failures, over: raw) : raw
        let guardian = AXHelpers.HelpReadGuard(allowHelpReads: true, stop: {
            calls.guards += 1
            return mode == "cutoff"
        })
        AXHelpers.HelpReadGuard.$current.withValue(guardian) {
            let occupied = AXLogicProElements.isOccupiedPluginSlotElement(group, runtime: runtime)
            #expect(occupied == !["unmatched", "cutoff"].contains(mode))
            if metadataPositive {
                #expect(calls.help == 0 && calls.guards == 0,
                    "Fresh sibling metadata already proves both positive controls; no unresolved sibling needs focus-moving Help")
                #expect(!failures.any)
            } else if mode == "cutoff" {
                #expect(calls.guards > 0 && calls.help == 0 && guardian.stopped)
            } else {
                #expect(calls.help > 0 && calls.guards == calls.help,
                    "Unresolved metadata must keep the full guardian on every actual Help read")
            }
            if mode == "fresh" {
                for element in [bypass, open] {
                    builder.setAttribute(element, kAXDescriptionAttribute as String, "Unclassified control")
                    builder.setAttribute(element, kAXHelpAttribute as String, "Unrelated Help")
                }
                #expect(!AXLogicProElements.isOccupiedPluginSlotElement(group, runtime: runtime))
                #expect(calls.help > 0 && calls.guards == calls.help,
                    "The next classification must not reuse an earlier positive metadata sample")
            }
        }
        #expect(builder.actionCalls.isEmpty && builder.setCalls.isEmpty)
    }

    @Test("failure-noting delegation retains one fresh full guard per actual Help read",
          arguments: ["legacy", "typed", "raw_legacy", "raw_typed", "nested", "native_failure", "cutoff", "omitted", "fresh_cutoff"])
    func notedHelpReadGuardsTheNativeBoundaryOnce(mode: String) throws {
        final class Calls: @unchecked Sendable { var guards = 0, native = 0 }
        let builder = FakeAXRuntimeBuilder(), calls = Calls()
        let element = builder.element(1_971_990)
        builder.setAttribute(element, kAXHelpAttribute as String, "Native Help")
        let base = builder.makeAXRuntime()
        let native: @Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError> = { node, attribute in
            if attribute == kAXHelpAttribute as String {
                calls.native += 1
                if mode == "native_failure" { return .failure(.init(raw: AXError.cannotComplete.rawValue)) }
            }
            return .success(base.attributeValue(node, attribute))
        }
        let raw = AXHelpers.Runtime(axApp: base.axApp,
            attributeValue: { node, attribute in try? native(node, attribute).get() },
            setAttributeValue: base.setAttributeValue, children: base.children,
            performAction: base.performAction, childCount: base.childCount,
            attributeValueResult: native)
        let failures = AXPluginInstanceIdentity.FailedReads()
        let nestedFailures = AXPluginInstanceIdentity.FailedReads()
        let noted = AXPluginInstanceIdentity.noting(failures, over: raw)
        let runtime = mode == "nested" ? AXPluginInstanceIdentity.noting(nestedFailures, over: noted) : noted
        let guardian = AXHelpers.HelpReadGuard(allowHelpReads: mode != "omitted", stop: {
            calls.guards += 1
            return mode == "cutoff" || (mode == "fresh_cutoff" && calls.guards > 1)
        })
        func read() -> String? {
            switch mode {
            case "legacy": return AXHelpers.getAttribute(element, kAXHelpAttribute as String, runtime: runtime)
            case "raw_legacy": return runtime.attributeValue(element, kAXHelpAttribute as String) as? String
            case "raw_typed": return (try? runtime.attributeValueResult?(element, kAXHelpAttribute as String).get()) as? String
            default:
                let result: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                    element, kAXHelpAttribute as String, runtime: runtime)
                return try? result.get()
            }
        }
        AXHelpers.HelpReadGuard.$current.withValue(guardian) {
            let first = read()
            #expect(calls.guards == 1, "Only the wrapper's deciding native boundary needs the full guard")
            let refused = mode == "cutoff" || mode == "omitted"
            #expect(calls.native == (refused ? 0 : 1))
            #expect(first == (refused || mode == "native_failure" ? nil : "Native Help"))
            if mode == "fresh_cutoff" {
                #expect(read() == nil)
                #expect(calls.guards == 2 && calls.native == 1 && guardian.stopped)
                #expect(read() == nil && calls.guards == 2 && calls.native == 1)
            } else if !refused {
                _ = read()
                #expect(calls.guards == 2 && calls.native == 2,
                    "Delegation must never cache permission for the next physical read")
            }
            if mode == "omitted" { #expect(!guardian.stopped && !failures.any) }
            if mode == "native_failure" { #expect(failures.any) }
        }
        #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
    }

    @Test("the owned reader omits MIDI disambiguation only for a current native fixed Audio type",
          arguments: [false, true], ["absent", "audio", "instrument", "aux", "duplicate", "malformed", "editable_name",
              "type_changed", "label_replaced", "source_retired", "document_changed",
              "empty", "editable_static", "editability_changed", "settable_unreadable",
              "settable_document_changed", "settable_source_retired"])
    func ownedPluginReaderReachesOnlyTheEligibleBatchSeam(noting: Bool, typeLabel: String) throws {
        final class Calls: @unchecked Sendable { var metadataBatches = 0, helpGuardCalls = 0, bypassHelp = 0, midiHelp = 0, typeValues = 0, documents = 0, typeSettable = 0 }
        let builder = FakeAXRuntimeBuilder(), calls = Calls()
        let strip = builder.element(1_965_860), insert = builder.element(1_965_861)
        let bypass = builder.element(1_965_862), open = builder.element(1_965_863)
        builder.setRole(strip, kAXLayoutItemRole as String)
        builder.setRole(insert, kAXGroupRole as String)
        builder.setAttribute(insert, kAXDescriptionAttribute as String, "Gain")
        for (control, role, label) in [(bypass, kAXCheckBoxRole as String, "Bypass"), (open, kAXButtonRole as String, "Open")] {
            builder.setRole(control, role)
            builder.setAttribute(control, kAXDescriptionAttribute as String, label)
            builder.setAttribute(control, kAXHelpAttribute as String, label)
            builder.setChildren(control, [])
        }
        builder.setAttribute(bypass, kAXValueAttribute as String, 0)
        builder.setChildren(insert, [bypass, open]); builder.setChildren(strip, [insert])
        let window = builder.element(1_965_864), mixer = builder.element(1_965_865)
        builder.setRole(window, kAXWindowRole as String)
        builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/OwnedStrip.logicx")
        builder.setRole(mixer, kAXGroupRole as String)
        builder.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
        builder.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
        builder.setChildren(mixer, [strip]); builder.setChildren(window, [mixer])
        builder.setAttribute(window, kAXTitleAttribute as String, "OwnedStrip - Tracks")
        let app = builder.element(1_965_866)
        builder.setRole(app, kAXApplicationRole as String)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setChildren(app, [window])
        let label = builder.element(1_965_867)
        let losesTypeProof = ["type_changed", "label_replaced", "source_retired", "document_changed", "editability_changed",
            "settable_document_changed", "settable_source_retired"].contains(typeLabel)
        if typeLabel != "absent" {
            builder.setRole(label, typeLabel == "editable_name" ? kAXTextFieldRole as String : kAXStaticTextRole as String)
            builder.setAttribute(label, kAXDescriptionAttribute as String, typeLabel == "editable_name" ? "name" : "label")
            builder.setAttribute(label, kAXValueAttribute as String,
                typeLabel == "malformed" ? NSNumber(value: 13) : typeLabel == "instrument" ? "Inst 1" : typeLabel == "aux" ? "Aux 1" : "Audio 13")
            builder.setChildren(label, [])
            builder.setChildren(strip, [label, insert])
            if typeLabel == "editable_static" {
                builder.setAttributeSettable(label, kAXValueAttribute as String, true)
            }
            if typeLabel == "empty" { builder.setChildren(strip, [label]) }
            if typeLabel == "duplicate" {
                let duplicate = builder.element(1_965_868)
                builder.setRole(duplicate, kAXStaticTextRole as String)
                builder.setAttribute(duplicate, kAXDescriptionAttribute as String, "label")
                builder.setAttribute(duplicate, kAXValueAttribute as String, "Audio 13")
                builder.setChildren(duplicate, [])
                builder.setChildren(strip, [label, duplicate, insert])
            }
        }
        let base = builder.makeAXRuntime(appElement: app)
        let metadata = [kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute] as [String]
        let native: @Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError> = { element, attribute in
            if attribute == kAXDocumentAttribute as String, CFEqual(element, window) { calls.documents += 1 }
            if attribute == kAXValueAttribute as String, CFEqual(element, label) {
                calls.typeValues += 1
                // Two producer values and two initial proof values precede the
                // deciding post-classification proof. Change the actual native
                // owner/control then, not a decoded observation or expected value.
                if calls.typeValues == 5 {
                    if typeLabel == "editability_changed" {
                        builder.setAttributeSettable(label, kAXValueAttribute as String, true)
                    }
                    if typeLabel == "type_changed" { builder.setAttribute(label, kAXValueAttribute as String, "Inst 1") }
                    if typeLabel == "document_changed" {
                        builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/ForeignStrip.logicx")
                    }
                    if typeLabel == "source_retired" { builder.setChildren(mixer, []) }
                    if typeLabel == "label_replaced" {
                        let replacement = builder.element(1_965_868)
                        builder.setRole(replacement, kAXStaticTextRole as String)
                        builder.setAttribute(replacement, kAXDescriptionAttribute as String, "label")
                        builder.setAttribute(replacement, kAXValueAttribute as String, "Audio 13")
                        builder.setChildren(replacement, [])
                        builder.setChildren(strip, [replacement, insert])
                    }
                }
            }
            if attribute == kAXHelpAttribute as String, CFEqual(element, bypass) { calls.bypassHelp += 1 }
            if attribute == kAXHelpAttribute as String, CFEqual(element, insert) { calls.midiHelp += 1 }
            return base.attributeValueResult?(element, attribute) ?? .success(base.attributeValue(element, attribute))
        }
        let raw = AXHelpers.Runtime(axApp: base.axApp, attributeValue: { try? native($0, $1).get() },
            attributeIsSettable: { element, attribute in
                if CFEqual(element, label), attribute == kAXValueAttribute as String {
                    calls.typeSettable += 1
                    if typeLabel == "settable_unreadable" { return nil }
                    if calls.typeSettable == 2 {
                        if typeLabel == "settable_document_changed" {
                            builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/ForeignStrip.logicx")
                        }
                        if typeLabel == "settable_source_retired" { builder.setChildren(mixer, []) }
                    }
                }
                return base.attributeIsSettable(element, attribute)
            }, setAttributeValue: base.setAttributeValue,
            children: base.children, performAction: base.performAction, childCount: base.childCount,
            childrenResult: base.childrenResult, attributeValueResult: native,
            attributeValuesResult: { element, attributes in
                if attributes == metadata { calls.metadataBatches += 1 }
                return .success(attributes.map { attribute -> AnyObject in
                    if attribute == kAXChildrenAttribute as String { return base.children(element) as CFArray }
                    return base.attributeValue(element, attribute) ?? NSNull()
                })
            })
        let failures = AXPluginInstanceIdentity.FailedReads()
        let ax = noting ? AXPluginInstanceIdentity.noting(failures, over: raw) : raw
        if noting { #expect(ax.attributeValuesResult == nil) }
        else { #expect(ax.attributeValuesResult != nil) }
        let logic = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax)
        let guardian = AXHelpers.HelpReadGuard(stop: { calls.helpGuardCalls += 1; return false })
        try OperationTraceContext.$current.withValue(OperationTraceContext(mutationGateAcquired: true)) {
            try AXHelpers.HelpReadGuard.$current.withValue(guardian) {
                let states = try #require(AccessibilityChannel.readChannelStrips(from: [strip], runtime: logic,
                    window: window, mixer: mixer,
                    readingRouting: false, readingScalarHelp: false, stoppingWhen: { guardian.stopped }))
                let ownedReaderDocumentReads = calls.documents
                let physical = try #require(states.first?.physicalBinding)
                let fullyObserved: Bool = try #require(states.first?.pluginsFullyObserved as Bool?)
                if losesTypeProof {
                    #expect(calls.typeValues >= 5, "The witness must reach the deciding native type bookend")
                    #expect(!fullyObserved)
                    #expect(states.first?.pluginsSource == nil && states.first?.pluginsReadError != nil,
                        "A lost native type/owner proof cannot publish the chain acquired without its MIDI census")
                } else {
                    #expect(states.first?.pluginsSource == "ax")
                    if typeLabel == "empty" {
                        let plugins = try #require(states.first?.plugins)
                        #expect(plugins.isEmpty)
                        #expect(calls.typeValues == 2 && ownedReaderDocumentReads == 1,
                            "No recognized slots means no MIDI disambiguation or added full owner scans after the ordinary type producer")
                    } else { #expect(states.first?.plugins.first?.name == "Gain") }
                    #expect(physical.currentIndex(runtime: logic) == 0,
                        "The cost witness must reach a currently owned native source, not a failed fixture lookup")
                    #expect(fullyObserved)
                }
                #expect(calls.metadataBatches == 0)
                if typeLabel == "audio" || losesTypeProof || typeLabel == "empty" {
                    #expect(calls.midiHelp == 0,
                        "The exact native fixed Audio type excludes an instrument without a MIDI Help absence census")
                } else {
                    #expect(calls.midiHelp > 0 && calls.helpGuardCalls > 0,
                        "Unresolved, non-Audio, malformed and editable labels retain guarded MIDI/instrument disambiguation")
                }
                #expect(!guardian.stopped && !failures.any)
                #expect(calls.bypassHelp == 0,
                    "The actual owned reader must not read Bypass Help just to find an Open control already present in sibling metadata")
                if typeLabel == "audio" {
                    builder.setAttribute(label, kAXValueAttribute as String, "Inst 1")
                    calls.midiHelp = 0
                    let next = try #require(AccessibilityChannel.readChannelStrips(from: [strip], runtime: logic,
                        window: window, mixer: mixer, readingRouting: false, readingScalarHelp: false,
                        stoppingWhen: { guardian.stopped }))
                    #expect(next.first?.pluginsSource == "ax" && calls.midiHelp > 0,
                        "The next extraction must not reuse the previous Audio proof")
                }
            }
        }
        #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
    }
    @Test("plugin semantic text pairs fresh non-Help metadata but retains the full separate Help guard",
          arguments: ["healthy", "legacy", "null_fallback", "failed_batch", "malformed_metadata", "help_cutoff", "next_sample"])
    func semanticTextCoalescesOnlyItsFreshMetadata(kind: String) {
        final class Calls: @unchecked Sendable {
            var singles = 0, batches = 0, help = 0, guardCalls = 0
            var blocked = false
        }
        let builder = FakeAXRuntimeBuilder(), calls = Calls()
        let element = builder.element(1_965_870)
        builder.setAttribute(element, kAXIdentifierAttribute as String, "slot-id")
        builder.setAttribute(element, kAXDescriptionAttribute as String, "Audio Plug-in")
        builder.setAttribute(element, kAXTitleAttribute as String, "FX")
        builder.setAttribute(element, kAXHelpAttribute as String, "Native Help")
        let base = builder.makeAXRuntime()
        let metadata = [kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute] as [String]
        let batch: (@Sendable (AXUIElement, [String]) -> Result<[AnyObject], AXHelpers.AXStatusError>)?
        if kind == "legacy" { batch = nil }
        else {
            batch = { node, attributes in
                calls.batches += 1
                #expect(attributes == metadata && !attributes.contains(kAXHelpAttribute as String))
                if kind == "failed_batch" { return .failure(.init(raw: AXError.cannotComplete.rawValue)) }
                let values = attributes.map { attribute -> AnyObject in
                    if kind == "null_fallback" { return NSNull() }
                    if kind == "malformed_metadata" { return NSNumber(value: 1) }
                    return base.attributeValue(node, attribute) ?? NSNull()
                }
                if kind == "help_cutoff" { calls.blocked = true }
                return .success(values)
            }
        }
        let runtime = AXHelpers.Runtime(axApp: base.axApp, attributeValue: { node, attribute in
            if metadata.contains(attribute) { calls.singles += 1 }
            if attribute == kAXHelpAttribute as String { calls.help += 1 }
            return base.attributeValue(node, attribute)
        }, setAttributeValue: base.setAttributeValue, children: base.children,
            performAction: base.performAction, childCount: base.childCount,
            attributeValueResult: { node, attribute in
                if metadata.contains(attribute) { calls.singles += 1 }
                return .success(base.attributeValue(node, attribute))
            }, attributeValuesResult: batch)
        let guardian = AXHelpers.HelpReadGuard(stop: { calls.guardCalls += 1; return calls.blocked })
        AXHelpers.HelpReadGuard.$current.withValue(guardian) {
            let first = AXLogicProElements.elementSearchText(element, runtime: runtime)
            if ["failed_batch", "malformed_metadata"].contains(kind) { #expect(first == "native help") }
            else if kind == "help_cutoff" { #expect(first == "slot-id audio plug-in fx") }
            else { #expect(first == "slot-id audio plug-in fx native help") }
            #expect(calls.batches == (kind == "legacy" ? 0 : 1))
            #expect(calls.singles == (["legacy", "null_fallback"].contains(kind) ? 3 : 0))
            #expect(calls.guardCalls == 1 && calls.help == (kind == "help_cutoff" ? 0 : 1))
            if kind == "help_cutoff" { #expect(guardian.stopped) }
            else { #expect(!guardian.stopped) }
            if kind == "next_sample" {
                builder.setAttribute(element, kAXDescriptionAttribute as String, "Changed insert")
                #expect(AXLogicProElements.elementSearchText(element, runtime: runtime) == "slot-id changed insert fx native help")
                #expect(calls.batches == 2 && calls.help == 2 && calls.guardCalls == 2)
            }
        }
        #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
    }
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
