@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #290 — the track-header pan slider is selected by identity, not by elimination.
///
/// `--probe-selection-census` measured `findPanControlInHeader` at **zero survivors of two
/// sliders** on Logic 12.x (ko): its predicate searched the children's `AXDescription` for
/// `headerPanHint`, and the pan slider has no `AXDescription` at all — nor an `AXIdentifier`, which
/// is absent from the element entirely. So the site fell through to "the slider that is not the
/// volume fader" on every header.
///
/// The strings below are transcribed from that live tree, not invented. A fixture written from
/// memory would pass while describing a UI Logic does not produce, which is the failure the census
/// itself exists to catch.
@Suite("Issue290HeaderPanIdentity")
struct Issue290HeaderPanIdentityTests {

    @Test("header scalars use fresh paired role/children samples without sharing inventories between fields",
          arguments: ["healthy", "late_role_loss", "late_child_loss", "null_fallback", "batch_failure", "malformed_role", "malformed_children"])
    func scalarWalkCoalescesOnlyOneFreshNodeSample(condition: String) {
        final class Reads: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [String] = []
            func record(_ event: String) { lock.withLock { events.append(event) } }
            var calls: [String] { lock.withLock { events } }
        }
        func sample(bulk: Bool) -> (Double?, Double?, [String]) {
            let builder = FakeAXRuntimeBuilder(), reads = Reads()
            let header = builder.element(965_801), volume = builder.element(965_802), pan = builder.element(965_803)
            for (element, description, maximum, value) in [(volume, "Volume", 1.0, 0.75), (pan, "Pan", 127.0, 32.0)] {
                builder.setRole(element, kAXSliderRole as String)
                builder.setAttribute(element, kAXDescriptionAttribute as String, description)
                builder.setAttribute(element, kAXMinValueAttribute as String, 0.0)
                builder.setAttribute(element, kAXMaxValueAttribute as String, maximum)
                builder.setAttribute(element, kAXValueAttribute as String, value)
                builder.setChildren(element, [])
            }
            builder.setChildren(header, [volume, pan])
            let group = builder.element(965_804)
            if condition == "malformed_children" {
                builder.setRole(group, kAXGroupRole as String)
                builder.setChildren(group, [volume, pan])
                builder.setChildren(header, [group])
            }
            let base = builder.makeAXRuntime()
            let batch: (@Sendable (AXUIElement, [String]) -> Result<[AnyObject], AXHelpers.AXStatusError>)?
            if bulk {
                batch = { element, attributes in
                    reads.record("batch")
                    if condition == "batch_failure" { return .failure(.init(raw: AXError.cannotComplete.rawValue)) }
                    return .success(attributes.map { attribute -> AnyObject in
                        if condition == "null_fallback" { return NSNull() }
                        if condition == "malformed_role", attribute == kAXRoleAttribute as String { return NSNumber(value: 1) }
                        if condition == "malformed_children", CFEqual(element, group), attribute == kAXChildrenAttribute as String {
                            return "not a child collection" as NSString
                        }
                        if attribute == kAXChildrenAttribute as String { return base.children(element) as CFArray }
                        return base.attributeValue(element, attribute) ?? NSNull()
                    })
                }
            } else { batch = nil }
            let runtime = AXHelpers.Runtime(axApp: base.axApp, attributeValue: { element, attribute in
                if attribute == kAXRoleAttribute as String { reads.record("role") }
                return base.attributeValue(element, attribute)
            }, setAttributeValue: base.setAttributeValue, children: { element in
                reads.record("children"); return base.children(element)
            }, performAction: base.performAction, childCount: base.childCount,
                childrenResult: { element in reads.record("children"); return .success(base.children(element)) },
                attributeValueResult: { element, attribute in
                    if attribute == kAXRoleAttribute as String { reads.record("role") }
                    if attribute == kAXChildrenAttribute as String {
                        reads.record("children"); return .success(base.children(element) as CFArray)
                    }
                    return .success(base.attributeValue(element, attribute))
                }, attributeValuesResult: batch)
            let volumeValue = AXLogicProElements.findVolumeFader(in: header, runtime: runtime)
                .flatMap { AXValueExtractors.extractSliderValue($0, runtime: runtime) }
            if condition == "late_role_loss" { builder.setRole(pan, kAXButtonRole as String) }
            if condition == "late_child_loss" { builder.setChildren(header, [volume]) }
            let panValue = AXLogicProElements.findPanControlInHeader(header, runtime: runtime)
                .flatMap { AXValueExtractors.extractSliderValue($0, runtime: runtime) }
            return (volumeValue, panValue, reads.calls)
        }
        let legacy = sample(bulk: false), paired = sample(bulk: true)
        #expect(paired.2.contains("batch"), "Reach the real scalar locator's native batch seam")
        if ["batch_failure", "malformed_role", "malformed_children"].contains(condition) {
            #expect(paired.0 == nil && paired.1 == nil)
        } else {
            #expect(paired.0 == legacy.0 && paired.1 == legacy.1)
            #expect(paired.0 == 0.75)
            #expect(paired.1 == (["late_role_loss", "late_child_loss"].contains(condition) ? nil : 32.0))
            if condition != "null_fallback" { #expect(paired.2.count < legacy.2.count) }
        }
    }

    private static let panHelp = "패닝 노브 및 밸런스 노브. 트랙 신호를 스테레오 필드에 위치하려면 수직으로 드래그합니다."
    private static let volumeHelp = "볼륨 페이더. 트랙의 재생 볼륨을 설정합니다."

    /// A header holding `sliders` in tree order. Each tuple is (description, help, maxValue).
    private static func header(
        _ sliders: [(description: String?, help: String?, maxValue: Double?)]
    ) -> (element: AXUIElement, sliders: [AXUIElement], runtime: AXHelpers.Runtime) {
        let builder = FakeAXRuntimeBuilder()
        let header = builder.element(1)
        builder.setAttribute(header, kAXRoleAttribute as String, kAXGroupRole as String)

        var elements: [AXUIElement] = []
        for (offset, spec) in sliders.enumerated() {
            let slider = builder.element(offset + 2)
            builder.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
            if let description = spec.description {
                builder.setAttribute(slider, kAXDescriptionAttribute as String, description)
            }
            if let help = spec.help {
                builder.setAttribute(slider, kAXHelpAttribute as String, help)
            }
            if let maxValue = spec.maxValue {
                builder.setAttribute(slider, kAXMaxValueAttribute as String, maxValue)
            }
            elements.append(slider)
        }
        builder.setChildren(header, elements)
        return (header, elements, builder.makeAXRuntime())
    }

    @Test("the pan slider is found by its own help text, not by being the one left over")
    func identityRatherThanElimination() {
        // A third, nameless slider placed FIRST. Elimination returns "the first slider that is not
        // the volume fader", which is this one — so on the previous code this header resolves to
        // the wrong control while reporting nothing. Identity has to reach past it.
        let tree = Self.header([
            (description: nil, help: nil, maxValue: nil),                        // decoy, first
            (description: nil, help: Self.panHelp, maxValue: 127),               // pan
            (description: "볼륨", help: Self.volumeHelp, maxValue: 233),          // volume
        ])

        let found = AXLogicProElements.findPanControlInHeader(tree.element, runtime: tree.runtime)

        #expect(found != nil, "the header did not resolve at all")
        if let pan = found {
            #expect(CFEqual(pan, tree.sliders[1]), "resolved to a slider that never named itself")
            #expect(!CFEqual(pan, tree.sliders[0]), "resolved to the decoy — this is elimination")
        }
    }

    @Test("the volume fader is not mistaken for the pan control")
    func volumeIsNotPan() {
        let tree = Self.header([
            (description: nil, help: Self.panHelp, maxValue: 127),
            (description: "볼륨", help: Self.volumeHelp, maxValue: 233),
        ])

        let candidates = AXLogicProElements.headerPanSliderCandidates(
            among: tree.sliders, runtime: tree.runtime)

        // One, not both: the separation is the point. Two candidates here would mean the hint
        // matches the volume fader's text as well, and the count below is what would catch it.
        #expect(candidates.count == 1, "\(candidates.count) sliders claimed to be the pan control")
        if let only = candidates.first {
            #expect(CFEqual(only, tree.sliders[0]))
        }
    }

    @Test("two sliders that both name themselves pan are refused, not resolved to the first")
    func ambiguityRefuses() {
        let tree = Self.header([
            (description: nil, help: Self.panHelp, maxValue: 127),
            (description: nil, help: Self.panHelp, maxValue: 127),
            (description: "볼륨", help: Self.volumeHelp, maxValue: 233),
        ])

        // Returning tree.sliders[0] here is exactly what the #628 census exists to find: a choice
        // among equals, made silently. There is nothing left to tell these two apart, so the honest
        // answer is that the header did not resolve.
        #expect(AXLogicProElements.findPanControlInHeader(tree.element, runtime: tree.runtime) == nil)
    }

    @Test("the value range separates two candidates when the help text cannot")
    func valueRangeNarrows() {
        // Same ambiguity as above, except one of the two carries the volume fader's range. The pan
        // slider's AXMaxValue was measured at 127 against the volume fader's 233, and unlike the
        // help string that signature does not depend on locale.
        let tree = Self.header([
            (description: nil, help: Self.panHelp, maxValue: 233),
            (description: nil, help: Self.panHelp, maxValue: 127),
        ])

        let found = AXLogicProElements.findPanControlInHeader(tree.element, runtime: tree.runtime)
        #expect(found != nil)
        if let found {
            #expect(CFEqual(found, tree.sliders[1]), "narrowed to the slider with the wrong range")
        }
    }

    @Test("a header where nothing names itself still resolves by elimination")
    func eliminationSurvivesForUnmeasuredTrees() {
        // Only the Korean help string is measured. A locale whose help text carries none of the
        // hint's variants must be no worse off than before this change — it falls through to
        // elimination exactly as it did, rather than losing the control entirely.
        let tree = Self.header([
            (description: "볼륨", help: nil, maxValue: 233),
            (description: nil, help: nil, maxValue: 127),
        ])

        let found = AXLogicProElements.findPanControlInHeader(tree.element, runtime: tree.runtime)
        #expect(found != nil)
        if let found {
            #expect(CFEqual(found, tree.sliders[1]), "elimination stopped working")
        }
    }
}
