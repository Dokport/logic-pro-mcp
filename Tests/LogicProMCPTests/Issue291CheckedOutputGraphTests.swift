import Foundation
@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

@Suite("#291 captured checked-output graph", .serialized)
struct Issue291CheckedOutputGraphTests {
    private final class FocusProofProbe: @unchecked Sendable {
        var checking = false
        var unrelatedChildrenReads = 0
        var permitted: Bool?
    }
    private func preparedFixture(bus: Bool = false, label: String? = nil) throws -> Issue291PhysicalStripReferenceTests.Fixture {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        let destination = label ?? (bus ? "Bus 1" : "Stereo Output")
        if bus || label != nil {
            for output in f.outputs { f.b.setAttribute(output, kAXDescriptionAttribute as String, destination) }
        }
        let stereo = f.b.element(2_919_001)
        f.b.setRole(stereo, "AXMenuItem")
        f.b.setAttribute(stereo, "AXTitle", destination)
        f.b.setAttribute(stereo, "AXMenuItemMarkChar", "✓")
        f.b.setChildren(stereo, [])
        let parent = f.b.element(2_919_002)
        let menu = f.b.element(2_919_003)
        let leaf = f.b.element(2_919_004)
        f.b.setRole(parent, "AXMenuItem"); f.b.setAttribute(parent, "AXTitle", bus ? "Bus" : "Output")
        f.b.setRole(menu, "AXMenu")
        f.b.setRole(leaf, "AXMenuItem"); f.b.setAttribute(leaf, "AXTitle", destination)
        f.b.setAttribute(leaf, "AXMenuItemMarkChar", "✓"); f.b.setChildren(leaf, [])
        f.b.setChildren(menu, [leaf]); f.b.setChildren(parent, [menu])
        f.b.setChildren(f.root, [stereo, parent])
        return f
    }

    @Test("The existing owned reader supplies a typed observation without parsing its receipt")
    func ownedOutputReadSuppliesTypedAssignment() async throws {
        let f = try preparedFixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let owner = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let read = await AXMixerStripBinding.$current.withValue(owner) {
            await AccessibilityChannel.getOutputObservation(runtime: f.logic, timing: .immediate)
        }
        #expect(read.assignment == .stereoOutput)
        #expect(try #require(sharedJSONObject(read.result.message))["state"] as? String == "A")
        #expect(f.mutations.map { $0.1 } == ["AXPress", "AXCancel"])
    }

    @Test("Fresh inspection acquires checked outputs only with explicit navigation permission", arguments: [false, true])
    func freshInspectionOwnsCheckedOutputs(navigation: Bool) async throws {
        let f = try preparedFixture(bus: true)
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let population = try await OperationTraceContext.$current.withValue(context) {
            try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                allowUINavigation: navigation), fileReader: .unavailable, stoppingWhen: { false })
        }
        #expect(population.stable)
        #expect(try #require(population.strips).count == 2)
        #expect(population.checkedOutputs.count == (navigation ? 2 : 0))
        #expect(population.checkedOutputs.allSatisfy { $0.assignment == .bus(1) })
        #expect(f.mutations.map { $0.1 } == (navigation ? ["AXPress", "AXCancel", "AXPress", "AXCancel"] : []))
    }

    @Test("Checked before-output capture uses the owned menu without promoting non-bus graph coverage",
          arguments: ["stereo", "physical", "no_output", "unknown", "navigation_denied", "missing_mark", "owner_loss"])
    func checkedNonBusBeforeCaptureRemainsLocal(kind: String) async throws {
        let label: String
        switch kind {
        case "physical": label = "Output 3-4"
        case "no_output": label = "No Output"
        case "unknown": label = "Unknown destination"
        default: label = "Stereo Output"
        }
        let f = try preparedFixture(label: label)
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let probe = FocusProofProbe()
        if kind == "missing_mark" {
            f.attributeReadResult = { _, attribute in
                attribute == "AXMenuItemMarkChar" ? .failure(.init(raw: AXError.cannotComplete.rawValue)) : nil
            }
        }
        if kind == "owner_loss" {
            f.onAttributeRead = { _, attribute in
                if attribute == "AXMenuItemMarkChar" {
                    probe.checking = true
                    f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                }
            }
        }
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let population: SessionPopulationObservation.FreshPopulation
        do {
            population = try await OperationTraceContext.$current.withValue(context) {
                try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                    allowUINavigation: kind != "navigation_denied"), fileReader: .unavailable, stoppingWhen: { false })
            }
        } catch {
            #expect(kind == "owner_loss")
            #expect(probe.checking, "The original document must actually change at the deciding menu read")
            for mutation in f.mutations {
                #expect(mutation.1 == kAXPressAction as String
                    ? f.outputs.contains(where: { CFEqual($0, mutation.0) }) : CFEqual(f.root, mutation.0))
            }
            return
        }
        if kind == "owner_loss" {
            #expect(probe.checking)
            #expect(!population.stable)
            #expect(population.checkedOutputs.isEmpty)
            return
        }
        #expect(population.stable)
        let expected: OutputAssignment? = kind == "stereo" ? .stereoOutput : kind == "physical" ? .physical(3, 4) : nil
        #expect(population.checkedOutputs.count == (expected == nil ? 0 : 2))
        for reading in population.checkedOutputs {
            #expect(reading.assignment == expected)
            #expect(reading.sendOrdinal == nil)
            #expect(try #require(population.strips).filter { $0.physicalBinding?.matches(reading.source) == true }.count == 1)
        }
        let navigates = expected != nil || kind == "missing_mark"
        #expect(f.mutations.map { $0.1 } == (navigates ? ["AXPress", "AXCancel", "AXPress", "AXCancel"] : []))
        for mutation in f.mutations {
            #expect(mutation.1 == kAXPressAction as String
                ? f.outputs.contains(where: { CFEqual($0, mutation.0) }) : CFEqual(f.root, mutation.0))
        }
        for output in f.outputs {
            #expect(f.b.attributeValue(output, kAXDescriptionAttribute as String) as? String == label)
        }
        let cache = StateCache(), registry = TargetRegistry()
        await cache.updateProject(try #require(population.project))
        if let tracks = population.tracks { await cache.updateTracks(tracks) }
        await cache.updateChannelStrips(try #require(population.strips))
        let boundary = await cache.captureBoundary(watching: SessionPopulationObservation.watchedSections)
        let capture = await SessionPopulationObservation.capture(cache: cache, targetRegistry: registry,
            fileReader: .unavailable, accepted: .init(reading: .init(state: await cache.auditSnapshot(),
                fileTrackCount: nil, projectFileNotBound: false), boundary: boundary, population: population))
        let graph = SessionPopulationObservation.routingGraph(capture: capture)
        #expect(!graph.complete)
        #expect(graph.coverage.mainOutput.state != .complete)
        #expect(graph.coverage.physicalOutput.state != .complete)
        #expect(!graph.edges.contains { $0.kind == .mainOutput })
    }

    @Test("Only request-held checked output contributes a physical-source bus edge",
          arguments: ["held", "absent", "other_owner", "conflict", "unstable"])
    func checkedOutputUsesTheCapturedPhysicalOwner(fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Issue291PhysicalStripReferenceTests.Fixture()
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            let cache = StateCache(); let registry = TargetRegistry()
            let states = try #require(AccessibilityChannel.defaultGetMixerStates(
                runtime: f.logic, stoppingWhen: { false }).states)
            await cache.updateProject(.init(name: "Session", filePath: f.bundle.path, source: "fixture"))
            await cache.updateDocumentState(true)
            await cache.updateChannelStrips(states)
            let base = await SessionPopulationObservation.capture(cache: cache,
                targetRegistry: registry, fileReader: .unavailable)
            let owner = try #require(states[0].physicalBinding)
            let source = try #require(base.mixerReference(at: 0))
            var fresh = SessionPopulationObservation.FreshPopulation(project: base.project,
                tracks: base.tracks, strips: states, fileTrackCount: nil,
                beganAt: base.beganAt, endedAt: base.endedAt, stable: fault != "unstable")
            if fault != "absent" {
                fresh.checkedOutputs = [.init(source: fault == "other_owner"
                    ? try #require(states[1].physicalBinding) : owner, assignment: .bus(1))]
                if fault == "conflict" { fresh.checkedOutputs.append(.init(source: owner, assignment: .bus(2))) }
            }
            let capture = SessionPopulationObservation.Capture(before: base.before, after: base.after,
                projectEpoch: base.projectEpoch, project: base.project, tracks: base.tracks,
                tracksFetchedAt: base.tracksFetchedAt, channelStrips: base.channelStrips,
                mixerFetchedAt: base.mixerFetchedAt, fileTrackCount: base.fileTrackCount,
                projectFileNotBound: base.projectFileNotBound,
                requestedProjectMatches: base.requestedProjectMatches,
                referencesEnabled: base.referencesEnabled, targetSnapshot: base.targetSnapshot,
                issued: base.issued, projectIssuance: base.projectIssuance,
                beganAt: base.beganAt, endedAt: base.endedAt, captureID: base.captureID,
                freshPopulation: fresh, mixerReferences: base.mixerReferences)
            let graph = SessionPopulationObservation.routingGraph(capture: capture)
            let edges = graph.edges.filter { $0.source == source.rawValue }
            if fault == "held" {
                let edge = try #require(edges.first)
                #expect(edges.count == 1)
                #expect(edge.kind == .mainOutput)
                #expect(edge.destination == "bus_1")
                #expect(graph.nodes.first { $0.id == "bus_1" }?.kind == .bus)
                #expect(graph.nodes.first { $0.id == "bus_1" }?.targetRef == nil)
                #expect(graph.coverage.mainOutput.state == .partial)
            } else { #expect(edges.isEmpty) }
            #expect(!graph.complete)
            #expect(graph.snapshotId == base.captureID)
            #expect(graph.coverage.stripTrackAssociation.state != .complete)
            #expect(!graph.edges.contains { $0.kind == .inputAssignment })
            let section = SessionPopulationObservation.routingSection(capture: capture, moved: false)
            let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(section)) as? [String: Any])
            let publishedEdges = try #require(object["edges"] as? [[String: Any]])
            #expect(publishedEdges.count == graph.edges.count)
            #expect(object["snapshot_id"] as? String == graph.snapshotId)
            #expect(f.mutations.isEmpty)
        }
    }

    @Test("Interrupted acquisition retains the already restored popup effects", arguments: [false, true])
    func interruptedReadRetainsKnownEffects(revoked: Bool) async throws {
        let f = try preparedFixture(bus: true)
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        do {
            _ = try await OperationTraceContext.$current.withValue(context) {
                try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                    allowUINavigation: true), fileReader: .unavailable,
                    navigationReferenceIsCurrent: { !revoked || f.mutations.count < 2 },
                    stoppingWhen: { !revoked && f.mutations.count >= 2 })
            }
            Issue.record("The interrupted acquisition must not publish a population")
        } catch let error as SessionPopulationObservation.NavigationAcquisitionError {
            #expect(error.effects.navigationPerformed)
            #expect(error.effects.attempted.contains("routing_popup"))
            #expect(error.effects.changed.contains("routing_popup"))
            #expect(error.effects.restoration == "restored")
        }
        #expect(f.mutations.map { $0.1 } == ["AXPress", "AXCancel"])
    }

    @Test("Cancellation after popup restoration keeps its cause at the next strip boundary")
    func restoredOutputCancellationKeepsItsCause() async throws {
        let f = try preparedFixture(bus: true)
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true,
            ownsGate: { gate.stillOwns(claim) },
            cancellationRequested: { f.mutations.count >= 2 })
        do {
            _ = try await OperationTraceContext.$current.withValue(context) {
                try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                    allowUINavigation: true), fileReader: .unavailable,
                    stoppingWhen: { f.mutations.count >= 2 })
            }
            Issue.record("Cancelled routing acquisition must not return a population")
        } catch let error as SessionPopulationObservation.NavigationAcquisitionError {
            #expect(error.cause as? SessionPopulationObservation.AcquisitionError == .cancelled)
            #expect(error.effects.navigationPerformed)
            #expect(error.effects.attempted == ["routing_popup"])
            #expect(error.effects.changed == ["routing_popup"])
            #expect(error.effects.restoration == "restored")
        }
        #expect(f.mutations.map { $0.1 } == ["AXPress", "AXCancel"])
    }

    @Test("An observed popup that cannot be cancelled remains an explicit UI change")
    func unclosedPopupWithholdsCheckedOutputs() async throws {
        let f = try preparedFixture(bus: true)
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        f.b.setActionNames(f.root, [])
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let population = try await OperationTraceContext.$current.withValue(context) {
            try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                allowUINavigation: true), fileReader: .unavailable, stoppingWhen: { false })
        }
        #expect(!population.stable)
        #expect(population.checkedOutputs.isEmpty)
        #expect(population.uiEffects.navigationPerformed)
        #expect(population.uiEffects.restoration == "partially_restored")
        #expect(population.uiEffects.changed.contains("routing_popup"))
        #expect(f.mutations.map { $0.1 } == ["AXPress"])
    }

    @Test("The acquisition Help guard permits only its owned popup search focus",
          arguments: [false, true], ["AXGroup", "AXMenuItem"])
    func ownedPopupSearchDoesNotStopCleanup(foreignFocus: Bool, wrapperRole: String) async throws {
        let f = try preparedFixture(bus: true)
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let search = f.b.element(2_919_010)
        let group = f.b.element(2_919_011)
        f.b.setRole(search, kAXTextFieldRole as String)
        f.b.setRole(group, wrapperRole)
        f.b.setChildren(search, []); f.b.setChildren(group, [search])
        f.b.setChildren(f.root, [group, f.b.element(2_919_001), f.b.element(2_919_002)])
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        let foreign = f.b.element(2_919_012)
        f.b.setRole(foreign, kAXTextFieldRole as String); f.b.setChildren(foreign, [])
        f.onAttributeRead = { _, _ in
            f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String,
                f.mutations.count % 2 == 1 ? (foreignFocus ? foreign : search) : f.window)
        }
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let scope = AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope()
        let guardian = AXHelpers.HelpReadGuard(stop: { f.mutations.count % 2 == 1 && !scope.permits() })
        let population = try await OperationTraceContext.$current.withValue(context) {
            try await AXHelpers.HelpReadGuard.$current.withValue(guardian) {
                try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                    allowUINavigation: true), fileReader: .unavailable, readFocusScope: scope,
                    stoppingBeforeAXRead: { guardian.stopped }, stoppingWhen: { guardian.stopped })
            }
        }
        if foreignFocus {
            #expect(!population.stable)
            #expect(population.checkedOutputs.isEmpty)
        } else {
            #expect(population.stable)
            #expect(population.checkedOutputs.count == 2)
            #expect(population.uiEffects.restoration == "restored")
            #expect(f.mutations.map { $0.1 } == ["AXPress", "AXCancel", "AXPress", "AXCancel"])
            #expect(!guardian.stopped)
        }
        #expect(!scope.permits())
    }

    @Test("Owned popup focus proof does not enumerate unrelated destination submenus")
    func popupFocusProofReadsOnlyTheFocusedParent() async throws {
        let f = try preparedFixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let search = f.b.element(2_919_020), group = f.b.element(2_919_021)
        f.b.setRole(search, kAXTextFieldRole as String)
        f.b.setRole(group, kAXGroupRole as String)
        f.b.setChildren(search, []); f.b.setChildren(group, [search])
        f.b.setChildren(f.root, [group, f.b.element(2_919_001), f.b.element(2_919_002)])
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        let probe = FocusProofProbe()
        f.onAttributeRead = { _, _ in
            f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String,
                f.mutations.count % 2 == 1 ? search : f.window)
        }
        f.onChildrenResultRead = { element in
            if probe.checking,
               CFEqual(element, f.b.element(2_919_001)) || CFEqual(element, f.b.element(2_919_002)) {
                probe.unrelatedChildrenReads += 1
            }
        }
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let owner = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        _ = await OperationTraceContext.$current.withValue(context) {
            await AXMixerStripBinding.$current.withValue(owner) {
                await AccessibilityChannel.getOutputObservation(runtime: f.logic, timing: .immediate,
                    observingPopupFocus: { proof in
                        guard let proof else { return }
                        probe.checking = true
                        probe.permitted = proof()
                        probe.checking = false
                    })
            }
        }
        let permitted = try #require(probe.permitted)
        #expect(permitted)
        #expect(probe.unrelatedChildrenReads == 0)
    }
}
