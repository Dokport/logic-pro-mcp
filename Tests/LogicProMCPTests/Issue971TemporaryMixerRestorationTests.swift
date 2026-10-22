@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("#971 temporary Mixer Hide observes native settlement", .serialized)
struct Issue971TemporaryMixerRestorationTests {
    private final class Settlement: @unchecked Sendable {
        var reads = 0
        var faultInjected = false
        var referenceCurrent = true
        var postHideReferenceChecks = 0
        var absenceBeforeReappearance = false
    }

    @Test func temporaryHideWaitsForTheRetainedMixerToDisappear() async throws {
        try await restore(fault: nil)
    }

    @Test func temporaryHideCannotPromoteAbsenceAcrossAnAwaitedCustodyCheck() async throws {
        let fixture = Issue969MixerVisibilitySetterTests.Fixture(showing: false)
        let settlement = Settlement()
        fixture.builder.setAttributeSettable(fixture.rail, kAXFocusedAttribute as String, true)
        let context = OperationTraceContext(mutationGateAcquired: true,
            deadline: ContinuousClock.now.advanced(by: .seconds(10)))
        let effects = try await OperationTraceContext.$current.withValue(context) {
            let prepared = AccessibilityChannel.OwnedMixerObservationNavigation(
                window: fixture.window, runtime: fixture.logicRuntime(), expectedProject: nil,
                requiresProjectReference: false, referenceIsCurrent: {
                    if fixture.events.last == "hide_mixer" {
                        settlement.postHideReferenceChecks += 1
                        // First: the pre-observation custody renewal. Second:
                        // the awaited renewal after a complete absence sample.
                        if settlement.postHideReferenceChecks == 2 {
                            if case .notFound = AXLogicProElements.mixerAreaLookup(
                                in: fixture.window, runtime: fixture.logicRuntime(), requiresCompleteAbsence: true) {
                                settlement.absenceBeforeReappearance = true
                            }
                            fixture.showing = true
                            fixture.updateVisibility()
                            settlement.faultInjected = true
                        }
                    }
                    return true
                })
            let navigation = try #require(prepared)
            await navigation.reveal(stoppingWhen: { false })
            let revealed = try #require(navigation.revealedMixer)
            #expect(CFEqual(revealed, fixture.mixer))
            return await navigation.restore(stoppingWhen: { false })
        }
        #expect(settlement.faultInjected && settlement.absenceBeforeReappearance,
            "Actually re-expose the retained Mixer after complete absence at the awaited boundary")
        #expect(fixture.events == ["open_view", "show_mixer", "open_view", "hide_mixer"])
        #expect(fixture.showing)
        let current = try #require(AXLogicProElements.mixerAreaLookup(
            in: fixture.window, runtime: fixture.logicRuntime()).mixer)
        #expect(CFEqual(current, fixture.mixer))
        #expect(effects.restoration == "not_restored")
        #expect(effects.reason == "mixer_restoration_unverified")
    }

    @Test(arguments: ["document", "window", "focus", "cancel", "gate", "reference", "replacement", "unreadable", "deadline"])
    func delayedHideCannotOutliveItsOriginalCustody(fault: String) async throws {
        try await restore(fault: fault)
    }

    private func restore(fault: String?) async throws {
        let fixture = Issue969MixerVisibilitySetterTests.Fixture(showing: false)
        let settlement = Settlement()
        fixture.builder.setAttributeSettable(fixture.rail, kAXFocusedAttribute as String, true)
        let replacement = fixture.builder.element(971_990)
        fixture.builder.setRole(replacement, kAXGroupRole as String)
        fixture.builder.setAttribute(replacement, kAXIdentifierAttribute as String, "Mixer")
        fixture.builder.setChildren(replacement, [])
        fixture.afterVisibilityChange = {
            if !fixture.showing {
                // Native Hide has returned and the original focus is back, but
                // the retained Mixer remains in the Accessibility tree briefly.
                fixture.builder.setChildren(fixture.window, [fixture.rail, fixture.mixer])
            }
        }
        fixture.attributeReadObserver = { element, attribute in
            guard fixture.events.last == "hide_mixer", CFEqual(element, fixture.mixer),
                  attribute == kAXIdentifierAttribute as String else { return }
            settlement.reads += 1
            if settlement.reads == 2, let fault, fault != "deadline" {
                settlement.faultInjected = true
                switch fault {
                case "document": fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                case "window": fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String, replacement)
                case "focus": fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, replacement)
                case "cancel": fixture.cancelled = true
                case "gate": fixture.gateOwned = false
                case "reference": settlement.referenceCurrent = false
                case "replacement": fixture.builder.setChildren(fixture.window, [fixture.rail, replacement])
                case "unreadable": fixture.unknownWindowChildren = true
                default: Issue.record("unknown settlement fault")
                }
            }
            if settlement.reads == 3, fault == nil { fixture.updateVisibility() }
        }
        let context = OperationTraceContext(mutationGateAcquired: true,
            ownsGate: { fixture.gateOwned },
            deadline: ContinuousClock.now.advanced(by: fault == "deadline" ? .seconds(1) : .seconds(10)),
            cancellationRequested: { fixture.cancelled })
        let effects = try await OperationTraceContext.$current.withValue(context) {
            let prepared = AccessibilityChannel.OwnedMixerObservationNavigation(
                window: fixture.window, runtime: fixture.logicRuntime(), expectedProject: nil,
                requiresProjectReference: false, referenceIsCurrent: { settlement.referenceCurrent })
            let navigation = try #require(prepared)
            await navigation.reveal(stoppingWhen: { false })
            let revealed = try #require(navigation.revealedMixer)
            #expect(CFEqual(revealed, fixture.mixer))
            return await navigation.restore(stoppingWhen: { false })
        }
        #expect(fixture.events == ["open_view", "show_mixer", "open_view", "hide_mixer"],
            "Observe settlement without reissuing Hide, a key fallback or a focus setter")
        #expect(!fixture.showing)
        if let fault {
            #expect(effects.restoration == "not_restored")
            #expect(effects.reason == "mixer_restoration_unverified")
            if fault == "deadline" { #expect(settlement.reads >= 2) }
            else { #expect(settlement.faultInjected, "Reach the late custody fault after the first pending sample") }
        } else {
            #expect(settlement.reads >= 3, "Actually observe the delayed native disappearance")
            #expect(effects.restoration == "restored")
            #expect(effects.reason == nil)
        }
    }
}
