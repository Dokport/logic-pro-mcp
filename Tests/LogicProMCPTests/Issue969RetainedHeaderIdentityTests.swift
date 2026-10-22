@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// Native counterexample: grouping Audio 6–8 reuses Audio 6's AX header for
/// the new Folder. Giving the Folder the same name also defeats name drift.
@Suite("#969 recycled track headers do not preserve track identity")
struct Issue969RetainedHeaderIdentityTests {
    private final class Fixture: @unchecked Sendable {
        let builder = FakeAXRuntimeBuilder()
        let app: AXUIElement
        let window: AXUIElement
        let rail: AXUIElement
        let headers: [AXUIElement]
        let fields: [AXUIElement]
        let disclosure: AXUIElement
        let cache = StateCache()
        let registry = TargetRegistry()
        var childRoleReads = 0
        var onChildRoleRead: (@Sendable (Int) -> Void)?

        init() {
            let b = builder
            app = builder.element(969_100)
            window = builder.element(969_101)
            rail = builder.element(969_102)
            headers = (0..<8).map { b.element(969_110 + $0 * 2) }
            fields = (0..<8).map { b.element(969_111 + $0 * 2) }
            disclosure = builder.element(969_140)
            builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
            builder.setAttribute(window, kAXTitleAttribute as String, "Fixture - Tracks")
            builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/FolderIdentity.logicx")
            builder.setAttribute(rail, kAXRoleAttribute as String, kAXListRole as String)
            builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
            for index in headers.indices {
                builder.setRole(headers[index], kAXLayoutItemRole as String)
                builder.setRole(fields[index], kAXTextFieldRole as String)
                builder.setAttribute(fields[index], kAXDescriptionAttribute as String, "Audio \(index + 1)")
                builder.setAttribute(fields[index], kAXValueAttribute as String, "0")
                builder.setChildren(fields[index], [])
                builder.setChildren(headers[index], [fields[index]])
            }
            builder.setRole(disclosure, kAXDisclosureTriangleRole as String)
            builder.setAttribute(disclosure, kAXValueAttribute as String, 0)
            builder.setChildren(disclosure, [])
            builder.setChildren(rail, headers)
            builder.setChildren(window, [rail])
            builder.setChildren(app, [window])
            builder.setAttribute(app, kAXWindowsAttribute as String, [window])
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        }

        var runtime: AXLogicProElements.Runtime {
            builder.makeLogicRuntime(appElement: app,
                attributeValueResultHandler: { [self] element, attribute in
                    if CFEqual(element, fields[5]), attribute == kAXRoleAttribute as String {
                        childRoleReads += 1
                        onChildRoleRead?(childRoleReads)
                    }
                    return nil
                },
                setAttributeHandler: { _, _, _ in Issue.record("identity resolution must not write"); return false },
                performActionHandler: { _, _ in Issue.record("identity resolution must not act"); return false },
                executeAppleScript: { _ in Issue.record("identity resolution must not script"); return .error("forbidden") })
        }

        func issue() async throws -> IssuedTrackReferences {
            let rows = try #require(AccessibilityChannel.defaultGetTrackStates(runtime: runtime))
            await cache.updateTracks(rows)
            return try #require(await TrackReferenceIssuance.issue(
                for: rows, registry: registry, snapshot: registry.currentSnapshot))
        }

        func groupWithSameNamedParent() {
            builder.setChildren(headers[5], [disclosure, fields[5]])
            builder.setChildren(rail, Array(headers.prefix(6)))
        }

        func insertSameNamedOrdinaryTrackAtOriginalOrdinal() {
            // Native insertion reuses the original ordinal's ordinary header,
            // while the original logical track moves to the following row.
            builder.setAttribute(fields[6], kAXDescriptionAttribute as String, "Audio 6")
            builder.setAttribute(fields[7], kAXDescriptionAttribute as String, "Audio 7")
            let last = builder.element(969_160)
            let name = builder.element(969_161)
            builder.setRole(last, kAXLayoutItemRole as String)
            builder.setRole(name, kAXTextFieldRole as String)
            builder.setAttribute(name, kAXDescriptionAttribute as String, "Audio 8")
            builder.setAttribute(name, kAXValueAttribute as String, "0")
            builder.setChildren(name, [])
            builder.setChildren(last, [name])
            builder.setChildren(rail, headers + [last])
        }

        func resolve(_ reference: TargetReference, operation: String = "track.select",
                     atFinalBoundary: (@Sendable () async -> Void)? = nil) async -> TargetRefResolver.Outcome {
            await TargetRefResolver.resolveMutationIndex(
                ["target_ref": .string(reference.rawValue)], targetRegistry: registry, cache: cache,
                operation: operation, invalidIndexResult: toolInvalidParamsResult("explicit index required"),
                liveTrackName: { [self] in AXLogicProElements.trackName(at: $0, runtime: runtime) },
                liveTrackNames: { [self] in AXLogicProElements.trackNames(runtime: runtime) },
                beforeFinalValidation: atFinalBoundary)
        }
    }

    private func requireRefusal(_ result: TargetRefResolver.Outcome) throws {
        guard case .failure(let refusal) = result else {
            Issue.record("the old reference must not select or mutate a replacement logical track")
            return
        }
        let body = try #require(sharedJSONObject(sharedToolText(refusal)))
        #expect(body["state"] as? String == "C")
        #expect(body["error"] as? String == "stale_target_reference")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
    }

    @Test(arguments: ["track.select", "track.rename", "mixer.set_volume", "mixer.set_pan", "track.mute", "track.solo", "track.arm"])
    func sameNameSameOrdinalRecycledHeaderRefuses(operation: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = Fixture()
            let references = try await f.issue()
            let original = try #require(references.byTrackIndex[5])
            let binding = try #require(await f.registry.resolve(original)?.physicalTrack)
            #expect(binding.currentIndex() == 5)
            f.groupWithSameNamedParent()
            try requireRefusal(await f.resolve(original, operation: operation))
            #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
        }
    }

    @Test func finalBoundaryReplacementAlsoRefuses() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = Fixture()
            let original = try #require(try await f.issue().byTrackIndex[5])
            try requireRefusal(await f.resolve(original, atFinalBoundary: { f.groupWithSameNamedParent() }))
            #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
        }
    }

    @Test(arguments: ["track.select", "track.rename", "mixer.set_volume", "mixer.set_pan", "track.mute", "track.solo", "track.arm"])
    func sameNameSameOrdinaryShapeInsertionRefusesTheOldReference(operation: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = Fixture()
            let original = try #require(try await f.issue().byTrackIndex[5])
            f.insertSameNamedOrdinaryTrackAtOriginalOrdinal()
            try requireRefusal(await f.resolve(original, operation: operation))
            #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
        }
    }

    @Test func freshOrdinaryPopulationCannotReviveItsRecycledReference() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = Fixture()
            let original = try #require(try await f.issue().byTrackIndex[5])
            f.insertSameNamedOrdinaryTrackAtOriginalOrdinal()
            let fresh = try #require(try await f.issue().byTrackIndex[5])
            #expect(fresh != original, "a changed native population cannot reissue the old logical target")
            f.builder.setChildren(f.rail, f.headers)
            for index in f.fields.indices {
                f.builder.setAttribute(f.fields[index], kAXDescriptionAttribute as String, "Audio \(index + 1)")
            }
            try requireRefusal(await f.resolve(original))
        }
    }

    @Test func ordinaryNameAndSelectionChangesDoNotChangePhysicalPopulationCustody() async throws {
        let f = Fixture()
        let original = try #require(try await f.issue().byTrackIndex[5])
        let binding = try #require(await f.registry.resolve(original)?.physicalTrack)
        f.builder.setAttribute(f.fields[5], kAXDescriptionAttribute as String, "Approved new name")
        f.builder.setAttribute(f.headers[5], kAXSelectedAttribute as String, true)
        #expect(binding.currentIndex() == 5)
        #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
    }

    @Test func latePopulationInsertionWithoutNameAmbiguityRefuses() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = Fixture()
            let original = try #require(try await f.issue().byTrackIndex[5])
            try requireRefusal(await f.resolve(original, atFinalBoundary: {
                f.insertSameNamedOrdinaryTrackAtOriginalOrdinal()
                // Keep the names unique so the existing ambiguity refusal does
                // not mask the deciding physical-population check.
                f.builder.setAttribute(f.fields[6], kAXDescriptionAttribute as String, "Audio 7")
                f.builder.setAttribute(f.fields[7], kAXDescriptionAttribute as String, "Audio 8")
                f.builder.setAttribute(f.builder.element(969_161), kAXDescriptionAttribute as String, "Audio 9")
            }))
            #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
        }
    }

    @Test func observedOrdinaryPopulationReplacementCannotReviveAfterUndo() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = Fixture()
            let original = try #require(try await f.issue().byTrackIndex[5])
            f.insertSameNamedOrdinaryTrackAtOriginalOrdinal()
            try requireRefusal(await f.resolve(original))
            f.builder.setChildren(f.rail, f.headers)
            for index in f.fields.indices {
                f.builder.setAttribute(f.fields[index], kAXDescriptionAttribute as String, "Audio \(index + 1)")
            }
            try requireRefusal(await f.resolve(original))
        }
    }

    @Test func ownedTemporaryExposurePreservesOriginalRowsAfterRestoration() throws {
        let f = Fixture()
        f.groupWithSameNamedParent()
        let original = Array(f.headers.prefix(6))
        f.builder.setAttribute(f.disclosure, kAXValueAttribute as String, 1)
        f.builder.setChildren(f.rail, f.headers)
        let exposure = AXTrackBinding.Exposure(header: f.headers[5], disclosure: f.disclosure,
            runtime: f.runtime, originalHeaders: original)
        let rows = try #require(AccessibilityChannel.readTrackStates(from: f.headers, in: f.window,
            runtime: f.runtime, exposure: exposure, readingTypeHelp: false, stoppingWhen: { false }).states)
        let outside = try #require(rows[0].physicalBinding)
        let acquired = try #require(rows[6].physicalBinding)
        exposure.end()
        f.builder.setAttribute(f.disclosure, kAXValueAttribute as String, 0)
        f.builder.setChildren(f.rail, original)
        #expect(outside.currentIndex() == 0, "owned temporary navigation preserves original outside rows")
        #expect(acquired.currentIndex() == nil, "an ended exposure never revives its acquired child")
        #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
    }

    @Test func structuralPopulationChangeRequiresFreshOutsideTrackReferences() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = Fixture()
            let original = try #require(try await f.issue().byTrackIndex[0])
            f.groupWithSameNamedParent()
            try requireRefusal(await f.resolve(original))
            let fresh = try #require(try await f.issue().byTrackIndex[0])
            #expect(fresh != original)
            guard case .success(let resolved) = await f.resolve(fresh) else {
                Issue.record("a fresh reference to the outside track must remain usable"); return
            }
            #expect(resolved.index == 0 && resolved.reference == fresh)
        }
    }

    @Test func freshParentGetsDifferentReference() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = Fixture()
            let original = try #require(try await f.issue().byTrackIndex[5])
            f.groupWithSameNamedParent()
            let fresh = try #require(try await f.issue().byTrackIndex[5])
            #expect(fresh != original, "a fresh parent must not inherit its hidden child's reference")
            try requireRefusal(await f.resolve(original))
        }
    }

    @Test func sampledReplacementCannotReviveAfterFlattening() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = Fixture()
            let original = try #require(try await f.issue().byTrackIndex[5])
            f.groupWithSameNamedParent()
            try requireRefusal(await f.resolve(original))
            f.builder.setChildren(f.headers[5], [f.fields[5]])
            f.builder.setChildren(f.rail, f.headers)
            try requireRefusal(await f.resolve(original))
        }
    }

    @Test func freshIssuanceObservationAlsoRetiresTheOriginalIdentity() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = Fixture()
            let original = try #require(try await f.issue().byTrackIndex[5])
            f.groupWithSameNamedParent()
            let parent = try #require(try await f.issue().byTrackIndex[5])
            #expect(parent != original)
            // Do NOT resolve the original while stacked. The fresh native
            // population itself has already observed its replacement.
            f.builder.setChildren(f.headers[5], [f.fields[5]])
            f.builder.setChildren(f.rail, f.headers)
            try requireRefusal(await f.resolve(original))
        }
    }

    @Test(arguments: ["document", "membership", "window"])
    func decidingShapeReadCannotOutliveScopeProof(change: String) async throws {
        let f = Fixture()
        let reference = try #require(try await f.issue().byTrackIndex[5])
        let binding = try #require(await f.registry.resolve(reference)?.physicalTrack)
        f.childRoleReads = 0
        #expect(binding.currentIndex() == 5)
        let decidingRead = f.childRoleReads
        #expect(decidingRead >= 2, "the native census and deciding shape scan must both execute")
        f.childRoleReads = 0
        f.onChildRoleRead = { count in
            guard count == decidingRead else { return }
            switch change {
            case "document":
                f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
            case "membership":
                f.builder.setChildren(f.rail, f.headers.filter { !CFEqual($0, f.headers[5]) })
            default:
                f.builder.setAttribute(f.app, kAXWindowsAttribute as String, [AXUIElement]())
            }
        }
        let index = binding.currentIndex()
        #expect(f.childRoleReads >= decidingRead, "the deciding-read fault must actually run")
        #expect(index == nil, "late shape evidence cannot authorize a foreign or absent track")
        #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
    }

    @Test func existingStackMayChangeDisclosureState() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = Fixture()
            f.groupWithSameNamedParent()
            let original = try #require(try await f.issue().byTrackIndex[5])
            f.builder.setAttribute(f.disclosure, kAXValueAttribute as String, 1)
            guard case .success(let resolved) = await f.resolve(original) else {
                Issue.record("a disclosure value change alone is not a replacement"); return
            }
            #expect(resolved.index == 5 && resolved.reference == original)
        }
    }

    @Test func oldStackReferenceCannotNameTheOrdinaryReplacement() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = Fixture()
            f.groupWithSameNamedParent()
            let original = try #require(try await f.issue().byTrackIndex[5])
            f.builder.setChildren(f.headers[5], [f.fields[5]])
            f.builder.setChildren(f.rail, f.headers)
            try requireRefusal(await f.resolve(original))
        }
    }

    @Test func unreadableChildIsNotProofOfUnchangedOrdinaryShape() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = Fixture()
            let original = try #require(try await f.issue().byTrackIndex[5])
            let unknown = f.builder.element(969_150)
            f.builder.setChildren(f.headers[5], [f.fields[5], unknown])
            try requireRefusal(await f.resolve(original))
            #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
        }
    }
}
