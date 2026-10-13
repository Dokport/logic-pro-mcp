@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#291 assigned-send owned checked-menu acquisition", .serialized)
struct Issue291AssignedSendMenuTests {
    private final class FinalFocusRevocation: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var values = 0
        private var fired = false
        func arm() { lock.withLock { armed = true } }
        func valueRead() { lock.withLock { if armed { values += 1 } } }
        func take() -> Bool {
            lock.withLock {
                guard armed, values >= 2, !fired else { return false }
                fired = true; return true
            }
        }
    }
    struct Prepared {
        let f: Issue291PhysicalStripReferenceTests.Fixture
        let anchor: AXUIElement
        let group: AXUIElement
        let bypass: AXUIElement
        let knob: AXUIElement
        let checkedEcho: AXUIElement
        let checkedLeaf: AXUIElement
    }
    private func prepare() throws -> Prepared {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        let anchor = f.b.element(291_900), group = f.b.element(291_901)
        let bypass = f.b.element(291_902), knob = f.b.element(291_903)
        f.b.setButton(anchor, description: "send button", help: "Send slot. Route signal.", x: 0, y: 0, width: 1, height: 1)
        f.b.setChildren(anchor, [])
        f.b.setRole(group, kAXGroupRole as String)
        // A deliberately misleading display cannot supply the typed destination.
        f.b.setAttribute(group, kAXDescriptionAttribute as String, "Bus 256")
        f.b.setRole(bypass, kAXCheckBoxRole as String)
        f.b.setAttribute(bypass, kAXValueAttribute as String, 0)
        f.b.setChildren(bypass, [])
        f.b.setAttribute(f.outputs[0], kAXDescriptionAttribute as String, "list")
        f.b.removeAttribute(f.outputs[0], kAXHelpAttribute as String)
        f.b.setActionNames(f.outputs[0], [kAXPressAction as String])
        f.b.setChildren(group, [bypass, f.outputs[0]])
        f.b.setRole(knob, kAXSliderRole as String)
        f.b.setAttribute(knob, kAXHelpAttribute as String, "Send Level knob. Set level.")
        f.b.setAttribute(knob, kAXValueAttribute as String, 0)
        f.b.setChildren(knob, [])
        f.b.setChildren(f.strips[0], [anchor, group, knob])
        let echo = f.b.element(291_910), parent = f.b.element(291_911)
        let menu = f.b.element(291_912), leaf = f.b.element(291_913), panner = f.b.element(291_914)
        for (e, title) in [(echo,"Bus 1 → Aux 1"),(parent,"Bus"),(leaf,"Bus 1 → Aux 1"),(panner,"Post Pan")] {
            f.b.setRole(e,kAXMenuItemRole as String); f.b.setAttribute(e,kAXTitleAttribute as String,title)
            f.b.setChildren(e,[])
        }
        for e in [echo,leaf,panner] { f.b.setAttribute(e,"AXMenuItemMarkChar","✓") }
        f.b.setRole(menu,kAXMenuRole as String); f.b.setChildren(menu,[leaf]); f.b.setChildren(parent,[menu])
        f.b.setChildren(f.root,[echo,panner,parent])
        return Prepared(f:f,anchor:anchor,group:group,bypass:bypass,knob:knob,checkedEcho:echo,checkedLeaf:leaf)
    }
    private func read(_ p: Prepared, ordinal: Int = 1, document: String? = nil) async -> ChannelResult {
        let f = p.f
        let binding = AXMixerStripBinding.Binding(window:f.window,mixer:f.mixer,strip:f.strips[0],document:document ?? f.bundle.absoluteString)
        return await AXMixerStripBinding.$current.withValue(binding) {
            await AccessibilityChannel.getAssignedSendVerified(ordinal:ordinal,runtime:f.logic,timing:.immediate)
        }
    }
    private final class SendWriterProbe: @unchecked Sendable {
        let p: Prepared
        let stereo: AXUIElement
        let pair: AXUIElement
        let mode: AXUIElement
        var current = "Stereo Output"
        var open = false
        var pressed: [String] = []
        var cancels = 0
        var foregroundLost = false
        var fault: String?
        init(_ p: Prepared) {
            self.p = p
            let b = p.f.b
            stereo = b.element(291_970); pair = b.element(291_971)
            mode = b.element(291_972)
            let output = b.element(291_973), outputs = b.element(291_974)
            let stereoParent = b.element(291_975), stereoMenu = b.element(291_976)
            for (e, title) in [(stereo,"Stereo Output"),(pair,"Output 3-4"),(mode,"Post Pan"),
                               (output,"Output"),(stereoParent,"Stereo")] {
                b.setRole(e,kAXMenuItemRole as String); b.setAttribute(e,kAXTitleAttribute as String,title)
                b.setAttribute(e,kAXEnabledAttribute as String,true); b.setChildren(e,[])
                b.setActionNames(e,[kAXPressAction as String])
            }
            b.setRole(outputs,kAXMenuRole as String); b.setRole(stereoMenu,kAXMenuRole as String)
            b.setChildren(stereoMenu,[stereo,pair]); b.setChildren(stereoParent,[stereoMenu])
            b.setChildren(outputs,[stereoParent]); b.setChildren(output,[outputs])
            b.setChildren(p.f.root,[p.checkedEcho,mode,output])
            b.setAttribute(p.f.app,kAXFrontmostAttribute as String,true)
            refresh()
        }
        func refresh() {
            let b = p.f.b
            b.setAttribute(p.checkedEcho,kAXTitleAttribute as String,current)
            b.setAttribute(p.checkedEcho,"AXMenuItemMarkChar","✓")
            b.setAttribute(stereo,"AXMenuItemMarkChar",current == "Stereo Output" ? "✓" : "")
            b.setAttribute(pair,"AXMenuItemMarkChar",current == "Output 3-4" ? "✓" : "")
            b.setAttribute(mode,"AXMenuItemMarkChar","✓")
        }
        func action(_ node: AXUIElement, _ action: String) -> Bool {
            let f = p.f
            if action == kAXCancelAction as String, CFEqual(node,f.root), open {
                cancels += 1
                open = false; f.b.setChildren(f.mixer,f.strips); return true
            }
            if action == kAXPressAction as String, CFEqual(node,f.outputs[0]) {
                open = true; refresh(); f.b.setChildren(f.mixer,f.strips + [f.root]); return true
            }
            if action == kAXPressAction as String, open, CFEqual(node,pair) || CFEqual(node,stereo) {
                let next = CFEqual(node,pair) ? "Output 3-4" : "Stereo Output"
                pressed.append(next)
                if fault != "no_effect" { current = next }
                if fault == "destination_label" {
                    f.b.setAttribute(f.outputs[0], kAXDescriptionAttribute as String, next)
                }
                if fault == "unreadable_label" {
                    f.b.removeAttribute(f.outputs[0], kAXDescriptionAttribute as String)
                }
                if fault == "control_retired" { f.b.setChildren(f.strips[0], [p.anchor, p.knob]) }
                if fault == "level" { f.b.setAttribute(p.knob,kAXValueAttribute as String,1) }
                if fault == "mode" { f.b.setAttribute(mode,kAXTitleAttribute as String,"Pre Fader") }
                if fault == "post_open_foreground" {
                    foregroundLost = true; refresh(); return true
                }
                if fault == "source_retired" { f.b.setChildren(f.mixer,[f.strips[1]]) }
                else { f.b.setChildren(f.mixer,f.strips) }
                open = false; refresh(); return true
            }
            Issue.record("Unexpected send action \(action)"); return false
        }
        var runtime: AXLogicProElements.Runtime {
            let f = p.f, base = f.logic
            let ax = f.b.makeAXRuntime(appElement:f.app,
                attributeValueResultHandler: { [self] node, _ in
                    guard fault == "strip_invalid", !pressed.isEmpty, CFEqual(node, f.strips[0]) else { return nil }
                    return .failure(.init(raw: -25202))
                },
                childrenResultHandler: { [self] node in
                    guard fault == "strip_invalid", !pressed.isEmpty, CFEqual(node, f.strips[0]) else { return nil }
                    return .failure(.init(raw: -25202))
                },
                actionNamesHandler: { [self] node in
                    guard CFEqual(node,pair) else { return nil }
                    switch fault {
                    case "late_wrong_project": f.b.setAttribute(f.window,kAXDocumentAttribute as String,"file:///wrong.logicx")
                    case "late_label": f.b.setAttribute(f.outputs[0],kAXDescriptionAttribute as String,"changed before press")
                    case "late_foreground": foregroundLost = true
                    case "late_background": f.b.setAttribute(f.app,kAXFrontmostAttribute as String,false)
                    case "late_foreign_editor":
                        let editor = f.b.element(291_978)
                        f.b.setRole(editor,kAXTextFieldRole as String); f.b.setChildren(editor,[])
                        f.b.setChildren(f.window,AXHelpers.getChildren(f.window,runtime:base.ax) + [editor])
                        f.b.setAttribute(f.app,kAXFocusedUIElementAttribute as String,editor)
                    default: return nil
                    }
                    return [kAXPressAction as String]
                },
                setAttributeHandler: { _,_,_ in Issue.record("Send parameter setter forbidden"); return false },
                performActionHandler: { [self] in action($0,$1) },
                performActionResultHandler: { [self] in action($0,$1) ? .success(()) : .failure(.init(raw:-25204)) })
            return .init(logicProPID:base.logicProPID,ax:ax,
                executeAppleScript: { _ in Issue.record("AppleScript forbidden"); return .error("forbidden") },
                onScreenWindowList: { [self] in open ? [[kCGWindowOwnerPID as String:f.pid,
                    kCGWindowLayer as String:LogicOnScreenWindows.popupMenuLevel]] : [] },
                postPopupMenuEscape: { Issue.record("Escape forbidden") },
                focusedApplicationPID: { [self] in foregroundLost ? f.pid + 1 : base.focusedApplicationPID() },
                observeFrontmost:base.observeFrontmost)
        }
        func write(destination: String = "physical:3-4", expected: String = "stereo_output",
                   replacement: Bool = true, ordinal: Int = 1) async -> ChannelResult {
            let f = p.f, gate = LogicMutationGate()
            guard let claim = gate.tryAcquire(operation:"logic_mixer.set_send_output_verified") else { return .error("gate") }
            defer { gate.release(claim) }
            let context = OperationTraceContext(mutationGateAcquired:true,ownsGate: { gate.stillOwns(claim) })
            return await OperationTraceContext.$current.withValue(context) {
                await AXMixerStripBinding.$current.withValue(.init(window:f.window,mixer:f.mixer,
                    strip:f.strips[0],document:f.bundle.absoluteString)) {
                    await AccessibilityChannel.setAssignedSendOutputVerified(params:["destination":destination,
                        "expected_current":expected,"replace_existing":replacement ? "true" : "false",
                        "send_ordinal":String(ordinal)],runtime:runtime,timing:.immediate)
                }
            }
        }
    }
    @Test("Occupied-send output replacement and explicit inverse retain level, bypass, mode and exact slot",
        arguments: ["fixed_label", "destination_label", "missing_identifiers"])
    func occupiedSendOutputRoundtrip(label: String) async throws {
        let p = try prepare(), probe = SendWriterProbe(p)
        probe.fault = label
        for (element, identifier) in [(p.f.strips[0], "original-source"), (p.group, "occupied-group"),
                                       (p.f.outputs[0], "occupied-list"), (p.bypass, "occupied-bypass")] {
            if label != "missing_identifiers" {
                p.f.b.setAttribute(element, kAXIdentifierAttribute as String, identifier)
            }
        }
        let before = AXLogicProElements.sendSlotObservations(in:p.f.strips[0],runtime:probe.runtime.ax)
        let forward = try #require(sharedJSONObject(await probe.write().message))
        #expect(forward["state"] as? String == "A", "\(forward)")
        if label == "missing_identifiers" {
            let identifiers = try #require(forward["pre_press_source_identifiers"] as? [String: Any])
            #expect(identifiers.count == 4 && identifiers.values.allSatisfy { $0 is NSNull })
        } else {
            #expect(forward["pre_press_source_identifiers"] as? [String: String] == [
                "strip": "original-source", "send_group": "occupied-group",
                "send_list": "occupied-list", "send_bypass": "occupied-bypass"])
            #expect(forward["pre_press_identifier_read_status"] as? [String: Int] == [
                "strip": 0, "send_group": 0, "send_list": 0, "send_bypass": 0])
        }
        let identity = try #require(forward["post_press_control_identity"] as? [String: Bool])
        #expect(identity == ["observed": true, "ordinal": true, "group": true,
            "list": true, "bypass": true, "parent_proxy": true, "source_path": true])
        #expect(probe.pressed == ["Output 3-4"])
        #expect(probe.current == "Output 3-4")
        let inverse = try #require(sharedJSONObject(await probe.write(destination:"stereo_output",expected:"physical:3-4").message))
        #expect(inverse["state"] as? String == "A", "\(inverse)")
        #expect(probe.pressed == ["Output 3-4","Stereo Output"])
        #expect(AXLogicProElements.sendSlotObservations(in:p.f.strips[0],runtime:probe.runtime.ax) == before)
        #expect(!probe.open)
    }
    @Test("Occupied-send refusals never press a destination",
        arguments:["stale", "empty", "replacement", "bus", "late_wrong_project", "late_label"])
    func occupiedSendOutputRefusals(fault: String) async throws {
        let p = try prepare(), probe = SendWriterProbe(p)
        probe.fault = fault
        let body = try #require(sharedJSONObject(await probe.write(destination:fault == "bus" ? "bus:1" : "physical:3-4",
            expected:fault == "stale" ? "physical:3-4" : "stereo_output",
            replacement:fault != "replacement",ordinal:fault == "empty" ? 0 : 1).message))
        #expect(body["state"] as? String == "C", "\(body)")
        #expect(probe.pressed.isEmpty)
        if fault == "late_label" { #expect(probe.cancels == 0) }
    }
    @Test("Post-press effect, protected-state and original-source loss remain uncertain; no guessed inverse",
        arguments:["no_effect", "level", "mode", "source_retired", "control_retired", "strip_invalid", "unreadable_label"])
    func occupiedSendOutputPostPressUncertainty(fault: String) async throws {
        let p = try prepare(), probe = SendWriterProbe(p)
        probe.fault = fault
        let body = try #require(sharedJSONObject(await probe.write().message))
        #expect(body["state"] as? String == "B", "\(body)")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(writeAttempted)
        #expect(probe.pressed == ["Output 3-4"])
        if fault == "control_retired" {
            let identity = try #require(body["post_press_control_identity"] as? [String: Bool])
            #expect(identity == ["observed": false])
        }
        if fault == "strip_invalid" {
            let statuses = try #require(body["post_press_source_read_status"] as? [String: Int])
            #expect(statuses["strip_role"] == -25202)
            #expect(statuses["strip_children"] == -25202)
        }
    }
    @Test("Revoked writer focus/foreground permits neither destination nor popup inverse",
        arguments:["late_foreground", "late_background", "late_foreign_editor", "post_open_foreground"])
    func occupiedSendCleanupCannotUseReaderOnlyCustody(fault: String) async throws {
        let p = try prepare(), probe = SendWriterProbe(p)
        probe.fault = fault
        let body = try #require(sharedJSONObject(await probe.write().message))
        #expect(body["state"] as? String == (fault == "post_open_foreground" ? "B" : "C"))
        #expect(probe.pressed == (fault == "post_open_foreground" ? ["Output 3-4"] : []))
        #expect(probe.cancels == 0)
        #expect(probe.open)
    }
    @Test("Registered occupied-send writer uses only a physical reference and the real mutation gate")
    func registeredOccupiedSendOutputWriter() async throws {
        let command = "set_send_output_verified"
        let spec = try #require(OperationRegistry.spec(tool:"logic_mixer",command:command))
        #expect(spec.mutability == .mutating)
        #expect(spec.indexBinding == .refRequired)
        #expect(spec.allowedParams == Set(["target_ref","project_ref","ordinal","destination","expected_current","replace_existing"]))
        let handler = try #require(OperationHandlerRegistry.handler(tool:"logic_mixer",command:command))
        let p = try prepare(), probe = SendWriterProbe(p)
        let cache = StateCache(), registry = TargetRegistry(), router = ChannelRouter()
        let channel = p.f.channel(logicOverride:probe.runtime)
        await router.register(channel)
        let poller = StatePoller(axChannel:channel,cache:cache,
            runtime:.init(hasVisibleWindow: { true },dialogPresent: { false },blockingDialogInfo: { nil },
                projectFileReader:.unavailable,keyboardFocus: { .notTextEditing }))
        #expect(await poller.refreshNow())
        let resource = try await ResourceHandlers.read(uri:"logic://mixer",cache:cache,router:router,
            targetRegistry:registry,fileReader:.unavailable)
        let rows = try #require(sharedJSONObject(sharedResourceText(resource))?["strips"] as? [[String:Any]])
        var matching: [String] = []
        for reference in rows.compactMap({ $0["mixer_strip_ref"] as? String }) {
            if let physical = await registry.resolve(.init(rawValue:reference))?.physicalMixerStrip,
               CFEqual(physical.strip,p.f.strips[0]) { matching.append(reference) }
        }
        #expect(matching.count == 1)
        let reference = try #require(matching.first)
        let dependencies = HandlerDependencies(router:router,cache:cache,targetRegistry:registry,poller:poller,
            dialogPresent: { false },supportBundleExporter:nil,mutationGate:LogicMutationGate(),
            liveTrackNames: { [0:"A",1:"B"] },projectFileReader:.unavailable)
        let params: [String:Value] = ["target_ref":.string(reference),"ordinal":.int(1),
            "destination":.object(["kind":.string("physical"),"ports":.array([.int(3),.int(4)])]),
            "expected_current":.object(["kind":.string("stereo_output")]),"replace_existing":.bool(true)]
        func call(_ inputs: [String:Value]) async -> CallTool.Result {
            await LogicProServer.runWithDeadline(tool:"logic_mixer",command:command,
                commandParams:inputs,mutationGate:dependencies.mutationGate) {
                await FeatureFlags.withAdr002TargetRefForTests(true) { await handler(dependencies,inputs) }
            }
        }
        for extra in ["track","index","value","bypassed"] {
            var invalid = params; invalid[extra] = .int(0)
            let body = try #require(sharedJSONObject(sharedToolText(await call(invalid))))
            #expect(body["state"] as? String == "C")
            #expect(probe.pressed.isEmpty)
        }
        for invalidReference in ["mix_unissued","trk_unissued"] {
            var invalid = params; invalid["target_ref"] = .string(invalidReference)
            let body = try #require(sharedJSONObject(sharedToolText(await call(invalid))))
            #expect(body["state"] as? String == "C")
            #expect(probe.pressed.isEmpty)
        }
        var wrongProject = params; wrongProject["project_ref"] = .string("prj_unissued")
        #expect(sharedJSONObject(sharedToolText(await call(wrongProject)))?["state"] as? String == "C")
        #expect(probe.pressed.isEmpty)
        let forward = try #require(sharedJSONObject(sharedToolText(await call(params))))
        #expect(forward["state"] as? String == "A", "\(forward)")
        #expect(probe.pressed == ["Output 3-4"])
        var inverse = params
        inverse["destination"] = params["expected_current"]
        inverse["expected_current"] = params["destination"]
        let restored = try #require(sharedJSONObject(sharedToolText(await call(inverse))))
        #expect(restored["state"] as? String == "A", "\(restored)")
        #expect(probe.pressed == ["Output 3-4","Stereo Output"])
        #expect(!probe.open)
        #expect(dependencies.mutationGate?.currentOperation() == nil)
    }
    @Test("Routing actions reuse the exact occupied census control, never an empty anchor or a lookalike",
          arguments: ["held", "negative", "empty", "missing_list", "duplicate_list", "foreign_parent"])
    func sharedAssignedSendControlRequiresOriginalCensus(fault: String) throws {
        let p = try prepare(), f = p.f
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        switch fault {
        case "missing_list": f.b.setChildren(p.group, [p.bypass])
        case "duplicate_list": f.b.setChildren(p.group, [p.bypass, f.outputs[0], f.outputs[0]])
        case "foreign_parent": f.b.setAttribute(p.group, kAXParentAttribute as String, f.strips[1])
        default: break
        }
        let control = AXLogicProElements.assignedSendMenuControl(in: f.strips[0],
            ordinal: fault == "negative" ? -1 : (fault == "empty" ? 0 : 1), runtime: f.logic.ax)
        if fault == "held" {
            let held = try #require(control)
            #expect(held.ordinal == 1)
            #expect(CFEqual(held.group, p.group))
            #expect(CFEqual(held.list, f.outputs[0]))
            #expect(CFEqual(held.bypass, p.bypass))
        } else { #expect(control == nil) }
        #expect(f.mutations.isEmpty)
    }
    @Test("Routing/association population reads inserts only when the strip footprint is requested",
          arguments: [SessionPopulationObservation.Domain.routing, .associations], [false, true])
    func routingPopulationSkipsUnrequestedInserts(domain: SessionPopulationObservation.Domain, includeStrips: Bool) async throws {
        let p = try prepare(), f = p.f
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let insert = Issue982UnreadChildrenTests.occupiedSlot(f.b, 291_950, name: "Compressor")
        f.b.setChildren(f.strips[1], [f.outputs[1], insert])
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let population = try await OperationTraceContext.$current.withValue(context) {
            try await f.channel().readFreshSessionPopulation(request: .init(
                domains: includeStrips ? [domain, .strips] : [domain]),
                fileReader: .unavailable, stoppingWhen: { false })
        }
        #expect(population.stable)
        let states = try #require(population.strips)
        #expect(!states.isEmpty)
        if includeStrips {
            #expect(states.contains { $0.pluginsSource != nil || $0.pluginsReadError != nil })
            #expect(states[1].plugins.count == 1)
        } else {
            #expect(states.allSatisfy { $0.pluginsSource == nil && $0.pluginsReadError == nil })
        }
        let cache = StateCache()
        await cache.updateProject(try #require(population.project))
        await cache.updateChannelStrips(states)
        let capture = await SessionPopulationObservation.capture(cache: cache,
            targetRegistry: nil, fileReader: .unavailable)
        let report = SessionPopulationObservation.build(request: .init(
            domains: includeStrips ? [domain, .strips] : [domain]), capture: capture)
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        let rows = try #require((wire["strips"] as? [String: Any])?["rows"] as? [[String: Any]])
        if includeStrips {
            #expect(rows[1]["plugin_count"] as? Int == 1)
        } else {
            #expect(rows[1]["plugin_count"] == nil || rows[1]["plugin_count"] is NSNull)
        }
        if domain == .routing || includeStrips {
            let hasSend = try #require(states.first?.sendSlots?.contains { $0.ordinal == 1 })
            #expect(hasSend)
        } else {
            // Association-only capture leaves unrequested routing unknown.
            #expect(states.allSatisfy { $0.sendSlots == nil })
        }
        #expect(f.mutations.isEmpty)
    }
    @Test("Explicit fresh routing capture retains the occupied send's checked destination")
    func freshRoutingCaptureReadsAssignedSend() async throws {
        let p = try prepare(), f = p.f
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let population = try await OperationTraceContext.$current.withValue(context) {
            try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                allowUINavigation: true), fileReader: .unavailable, stoppingWhen: { false })
        }
        #expect(population.stable)
        #expect(population.checkedOutputs.count == 1)
        #expect(population.checkedOutputs.first?.assignment == .bus(1))
        #expect(population.checkedOutputs.first?.sendOrdinal == 1)
        #expect(f.mutations.map { $0.1 } == ["AXPress", "AXCancel"])
        #expect(population.uiEffects.restoration == "restored")
    }
    @Test("Registered routing capture permits only its original nonediting physical or header focus under its Help guard",
          arguments: ["healthy", "editor", "settable", "characters", "line", "detached", "duplicate", "parent", "window", "background",
                      "header_healthy", "header_popup", "header_settable", "header_value", "header_line", "header_detached", "header_window", "header_background"])
    func guardedRoutingCaptureRetainsPassivePhysicalFocus(fault input: String) async throws {
        let p = try prepare(), f = p.f
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let isHeader = input.hasPrefix("header_")
        let fault = input == "header_popup" ? "healthy" : (isHeader ? String(input.dropFirst(7)) : input)
        let focus = isHeader ? passiveHeaderFocus(f) : try passivePhysicalFocus(f)
        if input == "header_popup" {
            let search = f.b.element(291_960)
            f.b.setRole(search, kAXTextFieldRole as String)
            f.b.setChildren(search, [])
            f.b.setChildren(f.root, try AXHelpers.childrenResult(f.root, runtime: f.logic.ax).get() + [search])
            f.onAttributeRead = { element, attribute in
                guard CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String else { return }
                // Focus changes with the owned action, not midway through the
                // popup witness's deciding read of its retained search identity.
                if f.mutations.last?.1 == kAXPressAction as String {
                    f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, search)
                } else if f.mutations.last?.1 == kAXCancelAction as String {
                    f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, focus)
                }
            }
        }
        switch fault {
        case "editor": f.b.setRole(focus, kAXTextFieldRole as String)
        case "settable": f.b.setAttributeSettable(focus, kAXValueAttribute as String, true)
        case "value": f.b.setAttribute(focus, kAXValueAttribute as String, NSNumber(value: 1))
        case "characters": f.b.setAttribute(focus, kAXNumberOfCharactersAttribute as String, 1)
        case "line": f.b.setAttribute(focus, kAXInsertionPointLineNumberAttribute as String, 1)
        case "detached":
            if isHeader { f.b.setChildren(f.headers[0], [f.headerVolumes[0], f.headerPans[0]]) }
            else { f.b.setChildren(f.mixer, [f.strips[0]]) }
        case "duplicate": f.b.setChildren(f.mixer, [f.strips[0], focus, focus])
        case "parent": f.b.setAttribute(focus, kAXParentAttribute as String, f.window)
        case "window": f.b.setAttribute(f.app, kAXFocusedWindowAttribute as String, f.app)
        case "background": f.b.setAttribute(f.app, kAXFrontmostAttribute as String, false)
        default: break
        }
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let scope = AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope()
        let guardian = AXHelpers.HelpReadGuard(allowHelpReads: true, stop: {
            AccessibilityChannel.readLogicKeyboardFocus(runtime: f.logic) != .notTextEditing && !scope.permits()
        })
        do {
            let population = try await OperationTraceContext.$current.withValue(context) {
                try await AXHelpers.HelpReadGuard.$current.withValue(guardian) {
                    try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                        allowUINavigation: true), fileReader: .unavailable, readFocusScope: scope,
                        stoppingBeforeAXRead: { guardian.stopped }, stoppingWhen: { guardian.stopped })
                }
            }
            #expect(fault == "healthy")
            #expect(population.stable)
            #expect(population.checkedOutputs.first?.sendOrdinal == 1)
            #expect(population.checkedOutputs.first?.assignment == .bus(1))
            #expect(f.mutations.map { $0.1 } == ["AXPress", "AXCancel"])
            let currentFocus: AXUIElement = try #require(AXHelpers.getAttribute(f.app,
                kAXFocusedUIElementAttribute as String, runtime: f.logic.ax))
            #expect(CFEqual(currentFocus, focus))
        } catch {
            #expect(fault != "healthy")
            #expect(f.mutations.isEmpty)
        }
        #expect(!scope.permits())
    }
    @Test("A checked send graph edge is tied to its source census, not a physical write slot",
          arguments: ["held", "absent", "other_owner", "conflict", "unstable", "empty", "duplicate_ordinal", "stereo", "physical", "invalid_bus", "invalid_physical", "no_output", "negative_ordinal", "moved", "decoded_known", "cache_only", "refs_stale"])
    func checkedSendGraphUsesOnlyHeldCensus(fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let p = try prepare(), f = p.f
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            var states = try #require(AccessibilityChannel.defaultGetMixerStates(
                runtime: f.logic, stoppingWhen: { false }).states)
            if fault == "empty" { states[0].sendSlots?[1].state = .observedEmpty }
            if fault == "duplicate_ordinal", let slot = states[0].sendSlots?[1] { states[0].sendSlots?.append(slot) }
            if fault == "decoded_known" {
                states[0].sendSlots?[1] = try JSONDecoder().decode(SendSlotObservation.self, from: Data(
                    #"{"ordinal":1,"state":"occupied_known_destination","checked_destination":"bus:1","destination_source":"ax_send_menu_checkmark","level_raw":0,"bypassed":false,"destination_display":"Bus 256"}"#.utf8))
            }
            let cache = StateCache(), registry = TargetRegistry()
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
                    ? try #require(states[1].physicalBinding) : owner,
                    assignment: fault == "stereo" ? .stereoOutput : (fault == "physical" ? .physical(3, 4)
                        : (fault == "invalid_physical" ? .physical(3, 3) : (fault == "invalid_bus" ? .bus(999)
                        : (fault == "no_output" ? .noOutput : .bus(1))))),
                    sendOrdinal: fault == "negative_ordinal" ? -1 : 1)]
                if fault == "conflict" {
                    fresh.checkedOutputs.append(.init(source: owner, assignment: .bus(2), sendOrdinal: 1))
                }
            }
            let capture = SessionPopulationObservation.Capture(before: base.before, after: base.after,
                projectEpoch: base.projectEpoch, project: base.project, tracks: base.tracks,
                tracksFetchedAt: base.tracksFetchedAt, channelStrips: base.channelStrips,
                mixerFetchedAt: base.mixerFetchedAt, fileTrackCount: base.fileTrackCount,
                projectFileNotBound: base.projectFileNotBound,
                requestedProjectMatches: base.requestedProjectMatches,
                referencesEnabled: base.referencesEnabled, targetSnapshot: base.targetSnapshot,
                issued: fault == "refs_stale" ? nil : base.issued, projectIssuance: base.projectIssuance,
                beganAt: base.beganAt, endedAt: base.endedAt, captureID: base.captureID,
                freshPopulation: fault == "cache_only" ? nil : fresh, mixerReferences: base.mixerReferences)
            let graph = fault == "moved" ? RoutingGraphPublication.publish(capture: capture, project: .moved)
                : SessionPopulationObservation.routingGraph(capture: capture)
            let edges = graph.edges.filter { $0.source == source.rawValue && $0.kind == .send }
            if fault == "held" {
                #expect(edges.count == 1)
                let edge = try #require(edges.first)
                #expect(edge.destination == "bus_1")
                #expect(edge.send == nil)
                #expect(edge.observedSendOrdinal == 1)
                #expect(edge.provenance.rawValue == "axSendMenuCheckmark")
                #expect(graph.nodes.first { $0.id == "bus_1" }?.targetRef == nil)
                #expect(graph.coverage.sends.state == .partial)
            } else { #expect(edges.isEmpty) }
            if fault != "moved" {
                let report = SessionPopulationObservation.build(request: .init(domains: [.routing, .strips]), capture: capture)
                let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
                let rows = try #require((wire["strips"] as? [String: Any])?["rows"] as? [[String: Any]])
                let slots = try #require(rows.first?["send_slots"] as? [[String: Any]])
                let slot = try #require(slots.first { $0["ordinal"] as? Int == 1 })
                if ["held", "stereo", "physical"].contains(fault) {
                    #expect(slot["state"] as? String == "occupied_known_destination")
                    let expected = fault == "stereo" ? "stereo_output" : (fault == "physical" ? "physical:3-4" : "bus:1")
                    #expect(slot["checked_destination"] as? String == expected)
                    #expect(slot["destination_source"] as? String == "ax_send_menu_checkmark")
                } else {
                    #expect(slot["state"] as? String == (fault == "empty" ? "observed_empty" : "occupied_unknown_destination"))
                    #expect(slot["checked_destination"] == nil)
                    #expect(slot["destination_source"] == nil)
                }
                #expect(slot["level_raw"] as? Double == 0)
                let bypassed = try #require(slot["bypassed"] as? Bool)
                #expect(!bypassed)
                #expect(slot["destination_display"] as? String == "Bus 256")
                #expect(states[0].sendSlots?[1].state == (fault == "empty" ? .observedEmpty
                    : (fault == "decoded_known" ? .occupiedKnownDestination : .occupiedUnknownDestination)))
            }
            #expect(!graph.complete)
            let decision = evaluate(.init(sourceTrackRef: source, physicalSlot: 1,
                destinationBusNumber: 1, destinationRef: nil, expectedProjectEpoch: graph.projectEpoch), against: graph)
            #expect(!decision.allowed)
            #expect(!decision.writeAttempted)
            #expect(f.mutations.isEmpty)
        }
    }
    private func passiveHeaderFocus(_ f: Issue291PhysicalStripReferenceTests.Fixture) -> AXUIElement {
        let label = f.b.element(291_940)
        f.b.setRole(label, kAXTextFieldRole as String)
        f.b.setAttribute(label, kAXValueAttribute as String, NSNumber(value: 0))
        f.b.setAttributeSettable(label, kAXValueAttribute as String, false)
        f.b.setAttribute(label, kAXWindowAttribute as String, f.window)
        f.b.setAttribute(label, kAXParentAttribute as String, f.headers[0])
        f.b.setChildren(label, [])
        f.b.setChildren(f.headers[0], [label, f.headerVolumes[0], f.headerPans[0]])
        f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, label)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        // The generic fake builder bridges NSNumber(0) through Bool. Preserve
        // the native CFNumber payload rather than qualifying a CFBoolean.
        f.attributeReadResult = { element, attribute in
            if CFEqual(element, label), attribute == kAXValueAttribute as String {
                return .success(f.b.attributeValue(element, attribute).map { $0 as AnyObject })
            }
            return nil
        }
        return label
    }
    private func passivePhysicalFocus(_ f: Issue291PhysicalStripReferenceTests.Fixture) throws -> AXUIElement {
        // Focus a different physical source, never the requested send's strip.
        let focus = f.strips[1], outer = f.b.element(291_950)
        let children = try AXHelpers.childrenResult(f.window, runtime: f.logic.ax).get()
        f.b.setRole(outer, kAXGroupRole as String)
        f.b.setAttribute(outer, kAXDescriptionAttribute as String, "Mixer")
        f.b.setChildren(outer, [f.mixer])
        f.b.setChildren(f.window, children.map { CFEqual($0, f.mixer) ? outer : $0 })
        f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, focus)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        f.b.setAttributeSettable(focus, kAXValueAttribute as String, false)
        f.b.setAttribute(focus, kAXNumberOfCharactersAttribute as String, 0)
        f.b.setAttribute(focus, kAXInsertionPointLineNumberAttribute as String, 0)
        f.attributeReadResult = { element, attribute in
            guard CFEqual(element, focus) else { return nil }
            if attribute == kAXValueAttribute as String || attribute == kAXSelectedTextAttribute as String {
                return .failure(.init(raw: AXError.noValue.rawValue))
            }
            return nil
        }
        return focus
    }
    @Test("An exact passive physical focus permits the different retained source's checked send read")
    func passivePhysicalFocusAllowsOnlyOwnedSendRead() async throws {
        let p = try prepare(), f = p.f
        let focus = try passivePhysicalFocus(f)
        #expect(AccessibilityChannel.readLogicKeyboardFocus(of: focus, runtime: f.logic) != .notTextEditing)
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "A")
        #expect((body["current_destination"] as? [String: Any])?["number"] as? Int == 1)
        #expect(body["popup_menu_state"] as? String == "closed")
        #expect(body["focus_restoration"] as? String == "restored")
        let wrote = try #require(body["write_attempted"] as? Bool)
        #expect(!wrote)
        #expect(f.mutations.count == 2)
        #expect(f.mutations.allSatisfy {
            (CFEqual($0.0, f.outputs[0]) && $0.1 == kAXPressAction as String)
                || (CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String)
        })
        #expect(AccessibilityChannel.readLogicKeyboardFocus(of: focus, runtime: f.logic) != .notTextEditing)
    }
    @Test("A passive physical focus exception still refuses editing, ambiguous and foreign ownership",
          arguments: ["editor", "settable", "characters", "line", "boolean_line", "detached", "duplicate", "parent", "window", "background", "unread"])
    func unsafePhysicalFocusCannotPress(_ fault: String) async throws {
        let p = try prepare(), f = p.f
        let focus = try passivePhysicalFocus(f)
        switch fault {
        case "editor": f.b.setRole(focus, kAXTextFieldRole as String)
        case "settable": f.b.setAttributeSettable(focus, kAXValueAttribute as String, true)
        case "characters": f.b.setAttribute(focus, kAXNumberOfCharactersAttribute as String, 1)
        case "line": f.b.setAttribute(focus, kAXInsertionPointLineNumberAttribute as String, 1)
        case "boolean_line": f.b.setAttribute(focus, kAXInsertionPointLineNumberAttribute as String, false)
        case "detached": f.b.setChildren(f.mixer, [f.strips[0]])
        case "duplicate": f.b.setChildren(f.mixer, [f.strips[0], focus, focus])
        case "parent": f.b.setAttribute(focus, kAXParentAttribute as String, f.window)
        case "window": f.b.setAttribute(f.app, kAXFocusedWindowAttribute as String, f.app)
        case "background": f.b.setAttribute(f.app, kAXFrontmostAttribute as String, false)
        case "unread":
            f.attributeReadResult = { element, attribute in
                guard CFEqual(element, focus) else { return nil }
                return .failure(.init(raw: attribute == kAXValueAttribute as String ? AXError.cannotComplete.rawValue : AXError.noValue.rawValue))
            }
        default: Issue.record("unknown physical focus fault")
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(body["current_destination"] == nil)
        #expect(f.mutations.isEmpty)
    }
    @Test("Revoking held physical focus at routing capability lookup refuses before the press")
    func passivePhysicalFocusRevocationBeforePress() async throws {
        let p = try prepare(), f = p.f
        _ = try passivePhysicalFocus(f)
        f.onActionNamesRead = { control in
            if CFEqual(control, f.outputs[0]) {
                f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.window)
            }
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(f.mutations.isEmpty)
    }
    @Test("A retained noneditable Arrange label permits only the owned routing-popup read")
    func passiveHeaderAllowsRoutingReadWithoutRelaxingKeyboardGate() async throws {
        let p = try prepare(), f = p.f
        let label = passiveHeaderFocus(f)
        #expect(AccessibilityChannel.readLogicKeyboardFocus(of: label, runtime: f.logic) != .notTextEditing)
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "A")
        #expect((body["current_destination"] as? [String: Any])?["number"] as? Int == 1)
        #expect(body["popup_menu_state"] as? String == "closed")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(f.mutations.count == 2)
        #expect(f.mutations.allSatisfy {
            (CFEqual($0.0, f.outputs[0]) && $0.1 == kAXPressAction as String)
                || (CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String)
        })
        #expect(AccessibilityChannel.readLogicKeyboardFocus(of: label, runtime: f.logic) != .notTextEditing)
    }
    @Test("Editing, ambiguous, foreign, or unreadable focus never permits a routing press",
          arguments: ["editable", "insertion", "selection", "text", "characters", "string_value", "boolean_value",
                      "wrong_window", "wrong_parent", "detached", "duplicate", "unread_attribute", "background"])
    func unsafeHeaderFocusHasNoAction(_ fault: String) async throws {
        let p = try prepare(), f = p.f
        let label = passiveHeaderFocus(f)
        switch fault {
        case "editable": f.b.setAttributeSettable(label, kAXValueAttribute as String, true)
        case "insertion": f.b.setAttribute(label, kAXInsertionPointLineNumberAttribute as String, 0)
        case "selection": f.b.setAttribute(label, kAXSelectedTextRangeAttribute as String, "0:0")
        case "text": f.b.setAttribute(label, kAXSelectedTextAttribute as String, "")
        case "characters": f.b.setAttribute(label, kAXNumberOfCharactersAttribute as String, 0)
        case "string_value": f.b.setAttribute(label, kAXValueAttribute as String, "0")
        case "boolean_value": f.b.setAttribute(label, kAXValueAttribute as String, false)
        case "wrong_window": f.b.setAttribute(label, kAXWindowAttribute as String, f.app)
        case "wrong_parent": f.b.setAttribute(label, kAXParentAttribute as String, f.headers[1])
        case "detached": f.b.setChildren(f.headers[0], [f.headerVolumes[0], f.headerPans[0]])
        case "duplicate": f.b.setChildren(f.headers[0], [label, label, f.headerVolumes[0], f.headerPans[0]])
        case "unread_attribute":
            f.attributeReadResult = { element, attribute in
                if CFEqual(element, label), attribute == kAXSelectedTextRangeAttribute as String {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                if CFEqual(element, label), attribute == kAXValueAttribute as String {
                    return .success(f.b.attributeValue(element, attribute).map { $0 as AnyObject })
                }
                return nil
            }
        case "background": f.b.setAttribute(f.app, kAXFrontmostAttribute as String, false)
        default: Issue.record("unknown injected fault")
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(body["current_destination"] == nil)
        #expect(f.mutations.isEmpty)
    }
    @Test("Focus or original header custody lost during capability lookup prevents the press",
          arguments: ["focus", "editable", "parent", "document"])
    func passiveFocusRevocationBeforePressHasNoAction(_ fault: String) async throws {
        let p = try prepare(), f = p.f
        let label = passiveHeaderFocus(f)
        f.onActionNamesRead = { control in
            guard CFEqual(control, f.outputs[0]) else { return }
            switch fault {
            case "focus": f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.headers[1])
            case "editable": f.b.setAttributeSettable(label, kAXValueAttribute as String, true)
            case "parent": f.b.setChildren(f.headers[0], [f.headerVolumes[0], f.headerPans[0]])
            case "document": f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///wrong.logicx")
            default: Issue.record("unknown injected revocation")
            }
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(body["current_destination"] == nil)
        #expect(f.mutations.isEmpty)
    }
    @Test("The final held-focus read cannot press a source whose project it just revoked")
    func documentRevocationInFinalFocusReadHasNoAction() async throws {
        let p = try prepare(), f = p.f
        let label = passiveHeaderFocus(f), revocation = FinalFocusRevocation()
        f.onActionNamesRead = { control in
            if CFEqual(control, f.outputs[0]) { revocation.arm() }
        }
        f.attributeReadResult = { element, attribute in
            if CFEqual(element, label), attribute == kAXValueAttribute as String {
                revocation.valueRead()
                return .success(f.b.attributeValue(element, attribute).map { $0 as AnyObject })
            }
            return nil
        }
        f.onAttributeRead = { element, attribute in
            if CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String, revocation.take() {
                f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///wrong.logicx")
            }
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(f.b.attributeValue(f.window, kAXDocumentAttribute as String) as? String == "file:///wrong.logicx")
        #expect(body["state"] as? String == "C")
        let navigated = try #require(body["navigation_attempted"] as? Bool)
        #expect(!navigated)
        #expect(f.mutations.isEmpty)
    }
    @Test("Bare checked bus echoes cannot bypass the legal bus domain", arguments:[1,256,257,999999])
    func checkedSendBusDomain(_ number: Int) async throws {
        let p = try prepare()
        for element in [p.checkedEcho,p.checkedLeaf] {
            p.f.b.setAttribute(element,kAXTitleAttribute as String,"Bus \(number)")
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        if OutputAssignment.busNumbers.contains(number) {
            #expect(body["state"] as? String == "A")
            let destination = try #require(body["current_destination"] as? [String:Any])
            #expect(destination["number"] as? Int == number)
        } else {
            #expect(body["state"] as? String == "C")
            #expect(body["current_destination"] == nil)
        }
        #expect(body["popup_menu_state"] as? String == "closed")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(p.f.mutations.count == 2)
    }
    @Test("Rejected bus roots remain routing competitors, not panner marks",
          arguments:["Bus 257","Bus 999999","Bus 257 → Aux 1"],[false,true])
    func rejectedBusCompetitorIsNotAbsence(_ title: String, _ checked: Bool) async throws {
        let p = try prepare(), f = p.f
        let competitor = f.b.element(291_930)
        f.b.setRole(competitor,kAXMenuItemRole as String)
        f.b.setAttribute(competitor,kAXTitleAttribute as String,title)
        f.b.setAttribute(competitor,"AXMenuItemMarkChar",checked ? "✓" : "")
        f.b.setChildren(competitor,[])
        f.b.setChildren(f.root,[p.checkedEcho,competitor,f.b.element(291_914),f.b.element(291_911)])
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == (checked ? "C" : "A"))
        if checked { #expect(body["current_destination"] == nil) }
        #expect(body["popup_menu_state"] as? String == "closed")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(f.mutations.count == 2)
    }
    @Test("Retained assigned list reads checked destination, never display or bypass/level", arguments:[false,true])
    func assignedSendReadsOwnedCheckmarks(_ failedACK: Bool) async throws {
        let p = try prepare(), f = p.f
        if failedACK { f.outputPressFailure = .init(raw:AXError.cannotComplete.rawValue) }
        let result = await read(p)
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["state"] as? String == "A")
        let destination = try #require(body["current_destination"] as? [String:Any])
        #expect(destination["kind"] as? String == "bus")
        #expect(destination["number"] as? Int == 1)
        #expect(body["popup_menu_state"] as? String == "closed")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(f.mutations.count == 2)
        if f.mutations.count == 2 {
            #expect(CFEqual(f.mutations[0].0,f.outputs[0]))
            #expect(f.mutations[0].1 == kAXPressAction as String)
            #expect(CFEqual(f.mutations[1].0,f.root))
            #expect(f.mutations[1].1 == kAXCancelAction as String)
        }
    }
    @Test("Empty/negative/out-of-range ordinal or wrong project has no action", arguments:[-1,0,2,99])
    func unboundSendHasNoAction(_ ordinal: Int) async throws {
        let p = try prepare()
        let body = try #require(sharedJSONObject(await read(p,ordinal:ordinal).message))
        #expect(body["state"] as? String == "C")
        #expect(p.f.mutations.isEmpty)
    }
    @Test func wrongProjectHasNoAction() async throws {
        let p = try prepare()
        let body = try #require(sharedJSONObject(await read(p,document:"file:///wrong.logicx").message))
        #expect(body["state"] as? String == "C")
        #expect(p.f.mutations.isEmpty)
    }
    @Test("Lookalike automation/group without qualified send anchor cannot be pressed")
    func unqualifiedGroupHasNoAction() async throws {
        let p = try prepare()
        p.f.b.setChildren(p.f.strips[0],[p.group,p.knob])
        let body = try #require(sharedJSONObject(await read(p,ordinal:0).message))
        #expect(body["state"] as? String == "C")
        #expect(p.f.mutations.isEmpty)
    }
    @Test func unadvertisedListCannotBePressed() async throws {
        let p = try prepare()
        p.f.b.setActionNames(p.f.outputs[0], [])
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(p.f.mutations.isEmpty)
    }
    @Test("A list that loses custody during capability lookup is not pressed")
    func listReplacementBeforePressRefuses() async throws {
        let p = try prepare(), f = p.f
        let replacement = f.b.element(291_920)
        f.b.setRole(replacement,kAXButtonRole as String)
        f.b.setAttribute(replacement,kAXDescriptionAttribute as String,"list")
        f.b.setChildren(replacement,[])
        f.onActionNamesRead = { control in
            if CFEqual(control,f.outputs[0]) { f.b.setChildren(p.group,[p.bypass,replacement]) }
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(f.mutations.isEmpty)
    }
    @Test("Group replacement after opening withholds destination and avoids unowned cleanup")
    func groupReplacementAfterPressRefuses() async throws {
        let p = try prepare(), f = p.f
        let replacement = f.b.element(291_921)
        f.b.setRole(replacement,kAXGroupRole as String)
        f.b.setAttribute(replacement,kAXDescriptionAttribute as String,"Bus 256")
        f.b.setChildren(replacement,[p.bypass,f.outputs[0]])
        // Reinstate the initial parent; the replacement is installed only after actual press.
        f.b.setChildren(p.group,[p.bypass,f.outputs[0]])
        f.onChildrenResultRead = { control in
            if CFEqual(control,f.mixer), !f.mutations.isEmpty {
                f.b.setChildren(f.strips[0],[p.anchor,replacement,p.knob])
            }
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(body["current_destination"] == nil)
        let navigationAttempted = try #require(body["navigation_attempted"] as? Bool)
        #expect(navigationAttempted)
        #expect(f.mutations.count == 1)
        #expect(f.mutations.allSatisfy { CFEqual($0.0,f.outputs[0]) && $0.1 == kAXPressAction as String })
    }
    @Test("Unreadable late competitor prevents both ordinal publication and any action")
    func unreadLateSendCensusHasNoAction() async throws {
        let p = try prepare(), f = p.f
        let unread = f.b.element(291_922)
        f.b.setRole(unread,kAXButtonRole as String); f.b.setChildren(unread,[])
        f.b.setChildren(f.strips[0],[p.anchor,p.group,p.knob,unread])
        f.attributeReadResult = { control,key in
            if CFEqual(control,unread), key == kAXHelpAttribute as String { return .failure(.init(raw:-25204)) }
            return nil
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(f.mutations.isEmpty)
    }
}
