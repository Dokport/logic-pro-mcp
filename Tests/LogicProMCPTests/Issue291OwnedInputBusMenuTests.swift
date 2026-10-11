@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#291 owned checked bus-input acquisition", .serialized)
struct Issue291OwnedInputBusMenuTests {
    struct Prepared {
        let f: Issue291PhysicalStripReferenceTests.Fixture
        let echo: AXUIElement
        let leaf: AXUIElement
        let inputLeaf: AXUIElement
    }
    private func prepare(_ number: Int = 1) throws -> Prepared {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        f.b.setAttribute(f.outputs[0],kAXDescriptionAttribute as String,"Bus 256")
        f.b.setAttribute(f.outputs[0],kAXHelpAttribute as String,"Input slot. Choose the channel strip input source.")
        f.b.setActionNames(f.outputs[0],[kAXPressAction as String])
        let echo=f.b.element(291_940), leaf=f.b.element(291_941), bus=f.b.element(291_942)
        let busMenu=f.b.element(291_943), input=f.b.element(291_944), inputMenu=f.b.element(291_945)
        let inputLeaf=f.b.element(291_946), noInput=f.b.element(291_947)
        for (element,title) in [(echo,"Bus \(number) ← Audio 2"),(leaf,"Bus \(number) ← Audio 2"),
                                (bus,"Bus"),(input,"Input"),(inputLeaf,"Input 1-2"),(noInput,"No Input")] {
            f.b.setRole(element,kAXMenuItemRole as String)
            f.b.setAttribute(element,kAXTitleAttribute as String,title)
            f.b.setChildren(element,[])
        }
        for element in [echo,leaf] { f.b.setAttribute(element,"AXMenuItemMarkChar","✓") }
        for element in [busMenu,inputMenu] { f.b.setRole(element,kAXMenuRole as String) }
        f.b.setChildren(busMenu,[leaf]); f.b.setChildren(bus,[busMenu])
        f.b.setChildren(inputMenu,[inputLeaf]); f.b.setChildren(input,[inputMenu])
        f.b.setChildren(f.root,[echo,noInput,input,bus])
        return Prepared(f:f,echo:echo,leaf:leaf,inputLeaf:inputLeaf)
    }
    private func read(_ p: Prepared, document: String? = nil) async -> ChannelResult {
        let f=p.f
        let binding=AXMixerStripBinding.Binding(window:f.window,mixer:f.mixer,strip:f.strips[0],document:document ?? f.bundle.absoluteString)
        return await AXMixerStripBinding.$current.withValue(binding) {
            await AccessibilityChannel.getInputBusVerified(runtime:f.logic,timing:.immediate)
        }
    }
    @Test("Input bus destinations follow the owning incoming-arrow menu, never its current echo",
          arguments: [1, 256])
    func inputDestinationChoiceUsesIncomingBusIdentity(_ number: Int) throws {
        let p = try prepare(number)
        // Exercise the existing structural selector with input semantics. An
        // incoming arrow is host bus identity, not a receiver-name join.
        let choice = AccessibilityChannel.outputMenuChoice(for: .bus(number),
            in: p.f.root, runtime: p.f.logic.ax, receiverArrow: "←")
        guard case .item(let selected, let path) = choice else {
            Issue.record("The unique offered input bus must be selectable: \(choice.failureLabel)")
            return
        }
        #expect(CFEqual(selected, p.leaf))
        #expect(!CFEqual(selected, p.echo))
        #expect(path == ["Bus", "Bus \(number) ← Audio 2"])
        #expect(p.f.mutations.isEmpty)
    }
    @Test("Input destination selection rejects opposite arrows and duplicate incoming choices",
          arguments: ["opposite_arrow", "duplicate", "physical_input"])
    func inputDestinationChoiceRefusesAmbiguousOrForeignChoices(_ fault: String) throws {
        let p = try prepare(1)
        if fault == "opposite_arrow" {
            p.f.b.setAttribute(p.leaf, kAXTitleAttribute as String, "Bus 1 → Audio 2")
        } else if fault == "duplicate" {
            let second = p.f.b.element(291_948)
            p.f.b.setRole(second, kAXMenuItemRole as String)
            p.f.b.setAttribute(second, kAXTitleAttribute as String, "Bus 1 ← Another receiver")
            p.f.b.setChildren(second, [])
            let busMenu = p.f.b.element(291_943)
            p.f.b.setChildren(busMenu, [p.leaf, second])
        } else {
            p.f.b.setAttribute(p.leaf, kAXTitleAttribute as String, "Input 1")
        }
        let choice = AccessibilityChannel.outputMenuChoice(for: .bus(1),
            in: p.f.root, runtime: p.f.logic.ax, receiverArrow: "←")
        if case .item = choice { Issue.record("Unknown or ambiguous input destinations must refuse") }
        #expect(p.f.mutations.isEmpty)
    }
    @Test("Own input list reads checked bus rather than display", arguments:[1,256])
    func checkedInputBus(_ number: Int) async throws {
        let p=try prepare(number), body=try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "A")
        let input=try #require(body["current_input"] as? [String:Any])
        #expect(input["kind"] as? String == "bus")
        #expect(input["number"] as? Int == number)
        #expect(body["popup_menu_state"] as? String == "closed")
        let write: Bool = try #require(body["write_attempted"] as? Bool)
        #expect(!write)
        #expect(p.f.mutations.count == 2)
        if p.f.mutations.count == 2 {
            #expect(CFEqual(p.f.mutations[0].0,p.f.outputs[0]))
            #expect(p.f.mutations[0].1 == kAXPressAction as String)
            #expect(CFEqual(p.f.mutations[1].0,p.f.root))
            #expect(p.f.mutations[1].1 == kAXCancelAction as String)
        }
    }
    @Test("Invalid bus choice and a checked nonbus competitor remain unknown", arguments:[false,true])
    func inputChoicesMustBeKnown(_ conflict: Bool) async throws {
        let p=try prepare(conflict ? 1 : 257)
        if conflict { p.f.b.setAttribute(p.inputLeaf,"AXMenuItemMarkChar","✓") }
        let body=try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(body["current_input"] == nil)
        #expect(body["popup_menu_state"] as? String == "closed")
        let write: Bool = try #require(body["write_attempted"] as? Bool)
        #expect(!write)
    }

    @Test("Routing inspection publishes only its owned checked bus input", arguments: [1, 256], [false, true])
    func inspectionPublishesCheckedInput(number: Int, navigation: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let p = try prepare(number), f = p.f
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            let gate = LogicMutationGate()
            let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
            defer { gate.release(claim) }
            let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
            let fresh = try await OperationTraceContext.$current.withValue(context) {
                try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                    allowUINavigation: navigation), fileReader: .unavailable, stoppingWhen: { false })
            }
            #expect(fresh.stable)
            let cache = StateCache(), registry = TargetRegistry()
            await cache.updateProject(try #require(fresh.project))
            await cache.updateDocumentState(true)
            await cache.updateChannelStrips(try #require(fresh.strips))
            let base = await SessionPopulationObservation.capture(cache: cache,
                targetRegistry: registry, fileReader: .unavailable)
            let receiver = try #require(base.mixerReference(at: 0))
            let capture = inputCapture(base, fresh: fresh)
            let graph = SessionPopulationObservation.routingGraph(capture: capture)
            let inputs = graph.edges.filter { $0.kind == .inputAssignment }
            if navigation {
                let input = try #require(inputs.first)
                #expect(inputs.count == 1)
                #expect(input.source == "bus_\(number)")
                #expect(input.destination == receiver.rawValue)
                #expect(input.provenance == .axInputMenuCheckmark)
                #expect(graph.nodes.first { $0.id == receiver.rawValue }?.kind == .physicalStrip)
                #expect(graph.coverage.busToAuxInput.state == .partial)
                #expect(f.mutations.map { $0.1 } == ["AXPress", "AXCancel"])
            } else {
                #expect(inputs.isEmpty)
                #expect(f.mutations.isEmpty)
            }
            #expect(!graph.complete)
            #expect(!graph.nodes.contains { $0.kind == .aux })
            #expect(graph.snapshotId == base.captureID)
        }
    }

    private func inputCapture(_ base: SessionPopulationObservation.Capture,
        fresh: SessionPopulationObservation.FreshPopulation) -> SessionPopulationObservation.Capture {
        SessionPopulationObservation.Capture(before: base.before, after: base.after,
                projectEpoch: base.projectEpoch, project: base.project, tracks: base.tracks,
                tracksFetchedAt: base.tracksFetchedAt, channelStrips: base.channelStrips,
                mixerFetchedAt: base.mixerFetchedAt, fileTrackCount: base.fileTrackCount,
                projectFileNotBound: base.projectFileNotBound, requestedProjectMatches: base.requestedProjectMatches,
                referencesEnabled: base.referencesEnabled, targetSnapshot: base.targetSnapshot,
                issued: base.issued, projectIssuance: base.projectIssuance,
                beganAt: base.beganAt, endedAt: base.endedAt, captureID: base.captureID,
                freshPopulation: fresh, mixerReferences: base.mixerReferences)
    }

    @Test("Input publication keeps exact owner, source census and unique typed evidence",
        arguments: ["held", "absent", "other_owner", "conflict", "unstable", "invalid_bus", "missing_slot"])
    func checkedInputPublicationRefusesUnsupportedEvidence(_ fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let p = try prepare(), f = p.f
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            var states = try #require(AccessibilityChannel.defaultGetMixerStates(
                runtime: f.logic, stoppingWhen: { false }).states)
            let owner = try #require(states[0].physicalBinding)
            if fault == "missing_slot" { states[0].inputSlotBinding = nil }
            let cache = StateCache(), registry = TargetRegistry()
            await cache.updateProject(.init(name: "Session", filePath: f.bundle.path, source: "fixture"))
            await cache.updateDocumentState(true)
            await cache.updateChannelStrips(states)
            let base = await SessionPopulationObservation.capture(cache: cache,
                targetRegistry: registry, fileReader: .unavailable)
            let receiver = try #require(base.mixerReference(at: 0))
            var fresh = SessionPopulationObservation.FreshPopulation(project: base.project,
                tracks: base.tracks, strips: states, fileTrackCount: nil,
                beganAt: base.beganAt, endedAt: base.endedAt, stable: fault != "unstable")
            if fault != "absent" {
                fresh.checkedInputs = [.init(receiver: fault == "other_owner"
                    ? try #require(states[1].physicalBinding) : owner,
                    busNumber: fault == "invalid_bus" ? 257 : 1)]
                if fault == "conflict" { fresh.checkedInputs.append(.init(receiver: owner, busNumber: 2)) }
            }
            let capture = inputCapture(base, fresh: fresh)
            let graph = SessionPopulationObservation.routingGraph(capture: capture)
            let inputs = graph.edges.filter { $0.kind == .inputAssignment }
            if fault == "held" {
                let input = try #require(inputs.first)
                #expect(inputs.count == 1)
                #expect(input.source == "bus_1")
                #expect(input.destination == receiver.rawValue)
            } else { #expect(inputs.isEmpty) }
            if fault == "held" { #expect(graph.provenance.contains(.axInputMenuCheckmark)) }
            else { #expect(!graph.provenance.contains(.axInputMenuCheckmark)) }
            #expect(!graph.complete)
            #expect(!graph.nodes.contains { $0.kind == .aux })
            #expect(f.mutations.isEmpty)
        }
    }

    @Test("Input acquisition never publishes a conflict or a population moved after cleanup",
        arguments: ["conflict", "moved", "not_restored"])
    func inputInspectionKeepsCleanupAndPopulationBookends(_ fault: String) async throws {
        let p = try prepare(), f = p.f
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        if fault == "conflict" { f.b.setAttribute(p.inputLeaf, "AXMenuItemMarkChar", "✓") }
        if fault == "not_restored" { f.b.setActionNames(f.root, []) }
        if fault == "moved" {
            f.attributeReadResult = { _, _ in
                if f.mutations.contains(where: { $0.1 == kAXCancelAction as String }) {
                    f.b.setAttribute(f.volumes[1], kAXValueAttribute as String, 101)
                }
                return nil
            }
        }
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let fresh = try await OperationTraceContext.$current.withValue(context) {
            try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                allowUINavigation: true), fileReader: .unavailable, stoppingWhen: { false })
        }
        #expect(fresh.checkedInputs.isEmpty)
        if fault == "conflict" { #expect(fresh.stable) }
        else { #expect(!fresh.stable) }
        if fault == "moved" { #expect(fresh.uiEffects.reason == "routing_population_moved") }
        if fault == "not_restored" { #expect(fresh.uiEffects.reason == "routing_popup_not_restored") }
        #expect(f.mutations.allSatisfy { $0.1 == "AXPress" || $0.1 == "AXCancel" })
    }
    @Test("Cleanup requires original input membership even when its AX role stays readable",
          arguments: ["healthy", "invalid_element", "readable_nonmember"])
    func originalInputMustSurviveCancel(_ mode: String) async throws {
        let p = try prepare(), f = p.f
        let retires = mode != "healthy"
        f.attributeReadResult = { element, _ in
            guard retires, f.mutations.contains(where: {
                CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String
            }) else { return nil }
            // Model loss of the original member after cleanup. The separate native
            // re-click observation kept readable attributes but lost membership;
            // it does not qualify that gesture as Cancel or a successful getter.
            f.reorder([1])
            if mode == "invalid_element", CFEqual(element, f.strips[0]) || CFEqual(element, f.outputs[0]) {
                return .failure(.init(raw: AXError.invalidUIElement.rawValue))
            }
            return nil
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == (retires ? "C" : "A"))
        let sourceAfter: Bool = try #require(body["source_custody_after_cleanup"] as? Bool)
        if retires { #expect(!sourceAfter) } else { #expect(sourceAfter) }
        let menuOwned: Bool = try #require(body["menu_custody_at_read"] as? Bool)
        #expect(menuOwned)
        #expect(body["output_checkmark_reads_observed"] as? Int == 2)
        let readsAgree: Bool = try #require(body["output_checkmark_reads_agree"] as? Bool)
        #expect(readsAgree)
        let cancelled: Bool = try #require(body["popup_cancel_succeeded"] as? Bool)
        #expect(cancelled)
        let writeAttempted: Bool = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        if retires {
            #expect(body["current_input"] == nil)
            for original in [f.strips[0], f.outputs[0]] {
                let retired: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                    original, kAXRoleAttribute as String, runtime: f.logic.ax)
                if mode == "invalid_element" {
                    if case .failure(let status) = retired {
                        #expect(status.raw == AXError.invalidUIElement.rawValue)
                    } else { Issue.record("The original source and input control must be retired") }
                } else if case .success(.some(let role)) = retired {
                    #expect(role == (CFEqual(original, f.strips[0]) ? kAXLayoutItemRole : kAXButtonRole) as String)
                } else { Issue.record("The nonmember source and control must remain AX-readable") }
            }
        } else {
            let input = try #require(body["current_input"] as? [String: Any])
            #expect(input["kind"] as? String == "bus")
            #expect(input["number"] as? Int == 1)
        }
        let current = try #require(AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: f.mixer, runtime: f.logic.ax))
        let originalStillMember = current.strips.contains(where: { CFEqual($0, f.strips[0]) })
        if retires { #expect(!originalStillMember) } else { #expect(originalStillMember) }
        if case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: f.logic) {
            #expect(CFEqual(window, f.window))
        } else { Issue.record("The original window must remain owned") }
        if case .found(let mixer) = AXLogicProElements.mixerAreaLookup(in: f.window, runtime: f.logic) {
            #expect(CFEqual(mixer, f.mixer))
        } else { Issue.record("The original Mixer must remain owned") }
        if case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(f.window, runtime: f.logic) {
            #expect(document == f.bundle.absoluteString)
        } else { Issue.record("The original document must remain owned") }
        #expect(f.mutations.count == 2)
        if f.mutations.count == 2 {
            #expect(CFEqual(f.mutations[0].0, f.outputs[0]))
            #expect(f.mutations[0].1 == kAXPressAction as String)
            #expect(CFEqual(f.mutations[1].0, f.root))
            #expect(f.mutations[1].1 == kAXCancelAction as String)
        }
    }
    @Test func wrongProjectDoesNotNavigate() async throws {
        let p=try prepare()
        let body=try #require(sharedJSONObject(await read(p,document:"file:///wrong.logicx").message))
        #expect(body["state"] as? String == "C")
        #expect(p.f.mutations.isEmpty)
    }
    @Test("Missing input or unadvertised press cannot navigate", arguments:[false,true])
    func inputControlMustBeQualified(_ missing: Bool) async throws {
        let p=try prepare()
        if missing {
            p.f.b.setAttribute(p.f.outputs[0],kAXHelpAttribute as String,"Output slot. Choose output.")
        } else {
            p.f.b.setActionNames(p.f.outputs[0],[])
        }
        let body=try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(p.f.mutations.isEmpty)
    }
    @Test("Input control replacement during capability lookup cannot acquire the replacement")
    func replacedInputControlDoesNotNavigate() async throws {
        let p=try prepare(), f=p.f
        let replacement=f.b.element(291_948)
        f.b.setButton(replacement,description:"Bus 256",help:"Input slot. Choose the channel strip input source.",x:0,y:0,width:1,height:1)
        f.b.setChildren(replacement,[])
        f.onActionNamesRead = { element in
            if CFEqual(element,f.outputs[0]) { f.b.setChildren(f.strips[0],[replacement]) }
        }
        let body=try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(f.mutations.isEmpty)
    }

    private func publishPublicInput(_ p: Prepared) async throws -> (dependencies: HandlerDependencies, source: String, track: String, project: String) {
        let f = p.f
        let cache = StateCache(), registry = TargetRegistry(), router = ChannelRouter()
        let channel = f.channel()
        await router.register(channel)
        let poller = StatePoller(axChannel: channel, cache: cache,
            runtime: .init(hasVisibleWindow: { true }, dialogPresent: { false }, blockingDialogInfo: { nil },
                projectFileReader: .unavailable, keyboardFocus: { .notTextEditing }))
        #expect(await poller.refreshNow())
        let mixer = try await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router,
            targetRegistry: registry, fileReader: .unavailable)
        let strips = try #require(sharedJSONObject(sharedResourceText(mixer))?["strips"] as? [[String: Any]])
        var source: String?
        for reference in strips.compactMap({ $0["mixer_strip_ref"] as? String }) {
            if let physical = await registry.resolve(TargetReference(rawValue: reference))?.physicalMixerStrip,
               CFEqual(physical.strip, f.strips[0]) { source = reference }
        }
        let tracks = try await ResourceHandlers.read(uri: "logic://tracks", cache: cache, router: router,
            targetRegistry: registry, fileReader: .unavailable)
        let trackRows = try #require(sharedJSONObject(sharedResourceText(tracks))?["data"] as? [[String: Any]])
        let track = try #require(trackRows.first?["track_ref"] as? String)
        let project = try await ResourceHandlers.read(uri: "logic://project/info", cache: cache, router: router,
            targetRegistry: registry, fileReader: .unavailable)
        let projectRef = try #require((sharedJSONObject(sharedResourceText(project))?["data"] as? [String: Any])?["project_ref"] as? String)
        #expect(f.mutations.isEmpty, "Issuing physical references must not navigate or write")
        let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry, poller: poller,
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: LogicMutationGate(),
            liveTrackNames: { [0: "A", 1: "B"] }, projectFileReader: .unavailable)
        return (dependencies, try #require(source), track, projectRef)
    }

    private func publicInput(_ dependencies: HandlerDependencies, params: [String: Value], referencesEnabled: Bool = true) async throws -> [String: Any] {
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_mixer", command: "get_input_bus_verified"))
        let result = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "get_input_bus_verified",
            commandParams: params, mutationGate: dependencies.mutationGate) {
                if let context = OperationTraceContext.current {
                    #expect(context.mutationGateAcquired,
                        "Popup acquisition and retained-source renewal require the real exclusive observation claim")
                    #expect(context.ownsGate())
                } else {
                    Issue.record("Popup acquisition must have an operation context")
                }
                // The deadline wrapper detaches its work. Set the test-only flag
                // inside that task rather than relying on inherited TaskLocals.
                return await FeatureFlags.withAdr002TargetRefForTests(referencesEnabled) {
                    await handler(dependencies, params)
                }
            }
        let completedGate = try #require(dependencies.mutationGate)
        #expect(completedGate.currentOperation() == nil,
            "Completed input observations must release their exclusive claim")
        return try #require(sharedJSONObject(sharedToolText(result)))
    }

    @Test func publicInputBusCannotEnterDuringAnotherOperation() async throws {
        let gate = LogicMutationGate()
        let predecessor = try #require(gate.tryAcquire(operation: "logic_tracks.rename"))
        defer { gate.release(predecessor) }
        let result = await LogicProServer.runWithDeadline(
            tool: "logic_mixer", command: "get_input_bus_verified", mutationGate: gate
        ) {
            Issue.record("Input popup acquisition entered while another operation owned Logic")
            return toolTextResult("unexpected acquisition")
        }
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "mutating_operation_in_progress")
        let attempted = try #require(body["write_attempted"] as? Bool)
        #expect(!attempted)
        #expect(gate.stillOwns(predecessor))
        #expect(gate.currentOperation() == "logic_tracks.rename")
    }

    @Test func publicInputBusContract() throws {
        let spec = try #require(OperationRegistry.spec(tool: "logic_mixer", command: "get_input_bus_verified"))
        #expect(spec.mutability == .readOnly)
        #expect(spec.allowedParams == Set(["target_ref", "project_ref"]))
        #expect(spec.deadline == .short)
        #expect(ChannelRouter.v2RoutingTable["mixer.get_input_bus_verified"] == [.accessibility])
        #expect(OperationHandlerRegistry.handler(tool: "logic_mixer", command: "get_input_bus_verified") != nil)
    }

    @Test(arguments: [1, 256])
    func publicInputBusReadsPhysicalReference(number: Int) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let p = try prepare(number), f = p.f
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            let published = try await publishPublicInput(p)
            var params: [String: Value] = ["target_ref": .string(published.source)]
            if number == 256 { params["project_ref"] = .string(published.project) }
            let body = try await publicInput(published.dependencies, params: params)
            #expect(body["state"] as? String == "A")
            #expect(body["operation"] as? String == "mixer.get_input_bus_verified")
            #expect(body["target_ref"] as? String == published.source)
            let input = try #require(body["current_input"] as? [String: Any])
            #expect(input["kind"] as? String == "bus")
            #expect(input["number"] as? Int == number, "The checked bus, not the misleading Bus 256 display, is authoritative")
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(!attempted)
            #expect(body["popup_menu_state"] as? String == "closed")
            #expect(f.mutations.count == 2)
            if f.mutations.count == 2 {
                #expect(CFEqual(f.mutations[0].0, f.outputs[0]) && f.mutations[0].1 == kAXPressAction as String)
                #expect(CFEqual(f.mutations[1].0, f.root) && f.mutations[1].1 == kAXCancelAction as String)
            }
            #expect(!f.mutations.contains { CFEqual($0.0, p.leaf) || CFEqual($0.0, p.inputLeaf) })
        }
    }

    @Test(arguments: ["track", "unknown", "removed"])
    func publicInputBusRejectsNonPhysicalOrStaleReference(target: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let p = try prepare(), f = p.f
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            let published = try await publishPublicInput(p)
            if target == "removed" { f.reorder([1]) }
            let reference = target == "track" ? published.track
                : (target == "unknown" ? "mix_missing_input_source" : published.source)
            let body = try await publicInput(published.dependencies, params: ["target_ref": .string(reference)])
            #expect(f.mutations.isEmpty)
            #expect(body["state"] as? String == "C")
            #expect(body["error"] as? String == "stale_target_reference")
            #expect(body["current_input"] == nil)
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(!attempted)
        }
    }

    @Test(arguments: ["track", "index", "value", "destination", "ordinal"])
    func publicInputBusRejectsWriteAndIndexInputs(extra: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let p = try prepare(), f = p.f
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            let published = try await publishPublicInput(p)
            let value: Value = extra == "destination" ? .object(["kind": .string("bus"), "number": .int(1)]) : .int(0)
            let body = try await publicInput(published.dependencies,
                params: ["target_ref": .string(published.source), extra: value])
            #expect(f.mutations.isEmpty)
            #expect(body["error"] as? String == "invalid_params")
            #expect(body["current_input"] == nil)
        }
    }

    @Test func publicInputBusRefusesDisabledReferences() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let p = try prepare(), f = p.f
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            let published = try await publishPublicInput(p)
            let body = try await publicInput(published.dependencies,
                params: ["target_ref": .string(published.source)], referencesEnabled: false)
            #expect(f.mutations.isEmpty)
            #expect(body["state"] as? String == "C")
            #expect(body["error"] as? String == "target_ref_unavailable")
            #expect(body["current_input"] == nil)
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(!attempted)
        }
    }
}
