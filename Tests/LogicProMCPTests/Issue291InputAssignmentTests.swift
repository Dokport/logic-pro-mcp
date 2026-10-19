@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#291 bounded input assignment", .serialized)
struct Issue291InputAssignmentTests {
    final class Fixture: @unchecked Sendable {
        let f: Issue291PhysicalStripReferenceTests.Fixture
        let input: AXUIElement
        let inputRoot: AXUIElement
        let echo: AXUIElement
        let one: AXUIElement
        let last: AXUIElement
        let outputRoot: AXUIElement
        var open: AXUIElement?
        var currentBus = 256
        var leafPresses: [Int] = []
        var noEffect = false
        var conflictAfterWrite = false
        var failedWriterOpenAcknowledgement = false
        var inputOpens = 0
        var popupReads: [String] = []
        var writerFocusFault: String?
        var lateFault: String?
        var lateFaultObserved = false
        var koreanInputAlias = false
        var ordinaryEffectCurrent = false
        var unownedPhysicalEffectAccepted = false

        init() throws {
            f = try .init()
            let b = f.b
            b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
            input = b.element(291_980); inputRoot = b.element(291_981)
            echo = b.element(291_982); one = b.element(291_983); last = b.element(291_984)
            outputRoot = b.element(291_985)
            b.setButton(input, description: "Bus 256", help: "Input slot. Choose the channel strip input source.",
                x: 0, y: 130, width: 60, height: 20)
            b.setActionNames(input, [kAXPressAction as String])
            b.setActionNames(f.outputs[0], [kAXPressAction as String])
            b.setChildren(input, [])
            let existing = AXHelpers.getChildren(f.strips[0], runtime: f.logic.ax)
            b.setChildren(f.strips[0], existing + [input])
            for (node, title) in [(echo, "Bus 256"), (one, "Bus 1 ← Sender"), (last, "Bus 256 ← Sender")] {
                b.setRole(node, kAXMenuItemRole as String)
                b.setAttribute(node, kAXTitleAttribute as String, title)
                b.setAttribute(node, kAXEnabledAttribute as String, true)
                b.setActionNames(node, [kAXPressAction as String])
                b.setChildren(node, [])
            }
            let bus = b.element(291_986), buses = b.element(291_987)
            b.setRole(bus, kAXMenuItemRole as String); b.setAttribute(bus, kAXTitleAttribute as String, "Bus")
            b.setRole(buses, kAXMenuRole as String); b.setChildren(buses, [one, last]); b.setChildren(bus, [buses])
            b.setRole(inputRoot, kAXMenuRole as String); b.setChildren(inputRoot, [echo, bus])
            b.setActionNames(inputRoot, [kAXCancelAction as String])
            let output = b.element(291_988), outputs = b.element(291_989)
            let stereo = b.element(291_990), outputEcho = b.element(291_991)
            for node in [stereo, outputEcho, output] { b.setRole(node, kAXMenuItemRole as String) }
            for node in [stereo, outputEcho] {
                b.setAttribute(node, kAXTitleAttribute as String, "Stereo Output")
                b.setAttribute(node, "AXMenuItemMarkChar", "✓"); b.setChildren(node, [])
            }
            b.setAttribute(output, kAXTitleAttribute as String, "Output")
            b.setRole(outputs, kAXMenuRole as String); b.setChildren(outputs, [stereo]); b.setChildren(output, [outputs])
            b.setRole(outputRoot, kAXMenuRole as String); b.setChildren(outputRoot, [outputEcho, output])
            b.setActionNames(outputRoot, [kAXCancelAction as String])
            refreshInputMarks()
        }
        func refreshInputMarks() {
            f.b.setAttribute(echo, kAXTitleAttribute as String,
                koreanInputAlias ? "Bus \(currentBus)  (버스 \(currentBus))" : "Bus \(currentBus)")
            if koreanInputAlias {
                f.b.setAttribute(one, kAXTitleAttribute as String, "Bus 1  (버스 1)")
                f.b.setAttribute(last, kAXTitleAttribute as String, "Bus 256  (버스 256)")
                f.b.setAttribute(f.b.element(291_986), kAXTitleAttribute as String, "버스")
            }
            f.b.setAttribute(echo, "AXMenuItemMarkChar", "✓")
            f.b.setAttribute(one, "AXMenuItemMarkChar", currentBus == 1 || conflictAfterWrite && !leafPresses.isEmpty ? "✓" : "")
            f.b.setAttribute(last, "AXMenuItemMarkChar", currentBus == 256 || conflictAfterWrite && !leafPresses.isEmpty ? "✓" : "")
        }
        func action(_ node: AXUIElement, _ action: String) -> Bool {
            if action == kAXCancelAction as String, let open, CFEqual(node, open) {
                self.open = nil; f.b.setChildren(f.mixer, f.strips)
                f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.window); return true
            }
            if action == kAXPressAction as String {
                if CFEqual(node, input) || CFEqual(node, f.outputs[0]) {
                    popupReads.append(CFEqual(node, input) ? "input" : "output")
                    open = CFEqual(node, input) ? inputRoot : outputRoot
                    refreshInputMarks(); f.b.setChildren(f.mixer, f.strips + [open!])
                    if CFEqual(node, input) {
                        inputOpens += 1
                        if inputOpens == 2, let writerFocusFault {
                            let search = f.b.element(291_992)
                            f.b.setRole(search, kAXTextFieldRole as String); f.b.setChildren(search, [])
                            if writerFocusFault.hasPrefix("owned_search") {
                                let rows = AXHelpers.getChildren(inputRoot, runtime: f.logic.ax)
                                f.b.setChildren(inputRoot, rows + [search])
                            } else {
                                f.b.setChildren(f.window, AXHelpers.getChildren(f.window, runtime: f.logic.ax) + [search])
                            }
                            f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, search)
                        }
                        if failedWriterOpenAcknowledgement && inputOpens == 2 { return false }
                    }
                    return true
                }
                if open.map({ CFEqual($0, inputRoot) }) == true, CFEqual(node, one) || CFEqual(node, last) {
                    let bus = CFEqual(node, one) ? 1 : 256
                    leafPresses.append(bus)
                    if !noEffect { currentBus = bus; f.b.setAttribute(input, kAXDescriptionAttribute as String, "Bus \(bus)") }
                    open = nil; f.b.setChildren(f.mixer, f.strips); refreshInputMarks()
                    f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.window); return true
                }
            }
            Issue.record("Unexpected input fixture action \(action)"); return false
        }
        var runtime: AXLogicProElements.Runtime {
            let base = f.logic
            let ax = f.b.makeAXRuntime(appElement: f.app,
                attributeValueResultHandler: { [self] node, attribute in
                    if CFEqual(node, f.app), attribute == kAXFocusedWindowAttribute as String,
                       inputOpens == 2, open != nil, writerFocusFault == "owned_search_no_focused_window" {
                        return .failure(.init(raw: AXError.noValue.rawValue))
                    }
                    return nil
                },
                actionNamesHandler: { [self] node in
                    if CFEqual(node, inputRoot), inputOpens == 2, lateFault == "cancel_wrong_project" {
                        lateFaultObserved = true
                        f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///wrong.logicx")
                        return [kAXCancelAction as String]
                    }
                    guard CFEqual(node, one), let lateFault else { return nil }
                    lateFaultObserved = true
                    switch lateFault {
                    case "detached_leaf": f.b.setChildren(f.b.element(291_987), [last])
                    case "source_changed": f.b.setAttribute(input, kAXDescriptionAttribute as String, "Bus 1")
                    case "wrong_project": f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///wrong.logicx")
                    case "foreground_lost": f.b.setAttribute(f.app, kAXFrontmostAttribute as String, false)
                    default: Issue.record("Unknown late fault")
                    }
                    return [kAXPressAction as String]
                },
                setAttributeHandler: { _, _, _ in Issue.record("Parameter setter forbidden"); return false },
                performActionHandler: { [self] in action($0, $1) },
                performActionResultHandler: { [self] in action($0, $1) ? .success(()) : .failure(.init(raw: -25204)) })
            return .init(logicProPID: base.logicProPID, ax: ax,
                executeAppleScript: { _ in Issue.record("AppleScript forbidden"); return .error("forbidden") },
                onScreenWindowList: { [self] in
                    var windows: [[String: Any]] = [[kCGWindowOwnerPID as String: f.pid,
                        kCGWindowNumber as String: 291_999, kCGWindowLayer as String: 0]]
                    if open != nil { windows.append([kCGWindowOwnerPID as String: f.pid,
                        kCGWindowNumber as String: 291_998, kCGWindowLayer as String: LogicOnScreenWindows.popupMenuLevel]) }
                    return windows
                }, postPopupMenuEscape: { Issue.record("Escape forbidden") },
                focusedApplicationPID: base.focusedApplicationPID, observeFrontmost: base.observeFrontmost)
        }
        func write(_ destination: Int, expected: Int = 256, replacement: Bool = true) async -> ChannelResult {
            let owner = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
                strip: f.strips[0], document: f.bundle.absoluteString)
            let gate = LogicMutationGate()
            guard let claim = gate.tryAcquire(operation: "logic_mixer.set_input_bus_verified") else {
                Issue.record("Fixture gate acquisition failed"); return .error("fixture")
            }
            defer { gate.release(claim) }
            let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
            return await OperationTraceContext.$current.withValue(context) {
              await AXMixerStripBinding.$current.withValue(owner) {
                await AccessibilityChannel.setInputBusVerified(params: ["destination": "bus:\(destination)",
                    "expected_current": "bus:\(expected)", "replace_existing": replacement ? "true" : "false"],
                    runtime: runtime, timing: .immediate)
              }
            }
        }
    }
    @Test("Actual checked input changes and explicitly requested inverse", arguments: [1, 256])
    func writesOnlyTheExactOfferedInput(_ destination: Int) async throws {
        let f = try Fixture()
        f.currentBus = destination == 1 ? 256 : 1
        f.f.b.setAttribute(f.input, kAXDescriptionAttribute as String, "Bus \(f.currentBus)")
        let before = f.currentBus
        let body = try #require(sharedJSONObject(await f.write(destination, expected: before).message))
        #expect(body["state"] as? String == "A", "Actual input receipt: \(body)")
        let verified = try #require(body["verified"] as? Bool); #expect(verified)
        #expect(f.leafPresses == [destination])
        #expect(f.currentBus == destination)
        #expect(f.popupReads.filter { $0 == "output" }.count == 2,
            "Acquire checked physical output once before the write and once after, without a redundant pre-input popup")
        #expect(Array(f.popupReads.suffix(2)) == ["output", "input"],
            "The final checked input/renewal must follow the last output popup rather than be invalidated by it")
        let inverse = try #require(sharedJSONObject(await f.write(before, expected: destination).message))
        #expect(inverse["state"] as? String == "A")
        #expect(f.leafPresses == [destination, before])
        #expect(f.currentBus == before)
        #expect(f.open == nil)
    }
    @Test func koreanInputAliasWriterUsesCheckedBeforeAndActualAfter() async throws {
        let f = try Fixture(); f.koreanInputAlias = true; f.refreshInputMarks()
        for (destination, before) in [(1, 256), (256, 1)] {
            let body = try #require(sharedJSONObject(await f.write(destination, expected: before).message))
            #expect(body["state"] as? String == "A", "Actual input alias writer: \(body)")
            #expect(f.currentBus == destination)
            #expect(f.open == nil)
        }
        #expect(f.leafPresses == [1, 256])
    }

    @Test func ordinaryInputEffectCannotBecomeAPhysicalInitialization() async throws {
        let f = try Fixture()
        let pair = AccessibilityChannel.HeldSelectionAssociation.Pair(
            track: .init(window: f.f.window, header: f.f.headers[1], document: f.f.bundle.absoluteString, runtime: f.runtime),
            strip: .init(window: f.f.window, mixer: f.f.mixer, strip: f.f.strips[0], document: f.f.bundle.absoluteString))
        let result = await AXMixerStripBinding.$outputAssociation.withValue(pair) {
            await AccessibilityChannel.$inputChangeObserver.withValue({ proof in
                f.ordinaryEffectCurrent = proof.permits() && proof.before == .bus(256) && proof.creation == nil
                let unowned = AccessibilityChannel.ChangedInputObservation(original: proof.original, current: proof.current,
                    renewal: proof.renewal, control: proof.control, population: proof.population, sink: proof.sink,
                    before: .physical([1, 2]), after: proof.after, creation: nil, focus: proof.focus,
                    checkedAfter: proof.checkedAfter, sampledAt: proof.sampledAt, heldFocus: nil)
                f.unownedPhysicalEffectAccepted = unowned.permits()
            }) { await f.write(1) }
        }
        #expect(try #require(sharedJSONObject(result.message))["state"] as? String == "A")
        #expect(f.ordinaryEffectCurrent && !f.unownedPhysicalEffectAccepted)
        #expect(f.leafPresses == [1])
    }

    @Test func publicPhysicalExpectedInputStillRefusesBeforeNavigation() async throws {
        let f = try Fixture()
        let owner = AXMixerStripBinding.Binding(window: f.f.window, mixer: f.f.mixer,
            strip: f.f.strips[0], document: f.f.bundle.absoluteString)
        let result = await AXMixerStripBinding.$current.withValue(owner) {
            await AccessibilityChannel.setInputBusVerified(params: ["destination": "bus:1", "expected_current": "input:1-2",
                "replace_existing": "true"], runtime: f.runtime, timing: .immediate)
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["state"] as? String == "C" && body["error"] as? String == "invalid_params")
        #expect(f.inputOpens == 0 && f.leafPresses.isEmpty)
    }

    @Test("Replacement and actual current input must agree before a write", arguments: [false, true])
    func refusesMissingReplacementOrStaleBefore(_ stale: Bool) async throws {
        let f = try Fixture()
        let body = try #require(sharedJSONObject(await f.write(1, expected: stale ? 1 : 256, replacement: stale).message))
        #expect(body["state"] as? String == "C")
        #expect(f.leafPresses.isEmpty)
        #expect(f.currentBus == 256)
    }
    @Test("A destination press is not verified effect", arguments: [false, true])
    func withholdsStateAForIgnoredWriteOrConflictingAfter(_ conflict: Bool) async throws {
        let f = try Fixture(); f.noEffect = !conflict; f.conflictAfterWrite = conflict
        let body = try #require(sharedJSONObject(await f.write(1).message))
        #expect(body["state"] as? String != "A")
        #expect(f.leafPresses == [1], "Actual input receipt: \(body)")
        #expect(f.open == nil)
    }
    @Test("Opener acknowledgement is not authority; actual owned checked menus decide")
    func observesEffectAfterFailedOpenerAcknowledgement() async throws {
        let f = try Fixture(); f.failedWriterOpenAcknowledgement = true
        let body = try #require(sharedJSONObject(await f.write(1).message))
        #expect(body["state"] as? String == "A")
        #expect(f.leafPresses == [1])
        #expect(f.open == nil)
        #expect(body["popup_menu_state"] as? String == "closed" || body["popup_menu_state"] as? String == "dismissed")
    }
    @Test("Late destination, source, project and foreground changes cannot press a leaf",
          arguments: ["detached_leaf", "source_changed", "wrong_project", "foreground_lost"])
    func rejectsLateCustodyChange(_ fault: String) async throws {
        let f = try Fixture(); f.lateFault = fault
        let body = try #require(sharedJSONObject(await f.write(1).message))
        #expect(f.lateFaultObserved)
        #expect(body["state"] as? String == "C")
        #expect(f.leafPresses.isEmpty)
        #expect(f.currentBus == 256)
        if fault == "detached_leaf" {
            #expect(f.open == nil)
        } else {
            #expect(f.open != nil)
            #expect(body["popup_menu_state"] as? String == "custody_lost")
        }
    }
    @Test("Stable original sources still require exact owned popup focus",
          arguments: ["foreign_editor", "owned_search", "owned_search_no_focused_window"])
    func stableSourceCannotWriteFromForeignEditor(_ fault: String) async throws {
        let f = try Fixture(); f.writerFocusFault = fault
        let body = try #require(sharedJSONObject(await f.write(1).message))
        if fault.hasPrefix("owned_search") {
            #expect(body["state"] as? String == "A"); #expect(f.leafPresses == [1])
        } else {
            #expect(body["state"] as? String == "C"); #expect(f.leafPresses.isEmpty)
            #expect(f.currentBus == 256)
        }
    }
    @Test("Cancel capability lookup cannot authorize cleanup after project revocation")
    func refusesLateWrongProjectCleanup() async throws {
        let f = try Fixture(); f.failedWriterOpenAcknowledgement = true; f.lateFault = "cancel_wrong_project"
        f.f.b.setAttribute(f.one, kAXTitleAttribute as String, "Bus 2 ← Sender")
        let body = try #require(sharedJSONObject(await f.write(1).message))
        #expect(f.lateFaultObserved)
        #expect(f.leafPresses.isEmpty)
        #expect(f.open != nil)
        #expect(body["popup_menu_state"] as? String == "custody_lost")
    }
    @Test("The registered input writer reaches the exact physical reference under the real gate")
    func registeredInputWriterUsesPhysicalReference() async throws {
        let spec = try #require(OperationRegistry.spec(tool: "logic_mixer", command: "set_input_bus_verified"))
        #expect(spec.mutability == .mutating)
        #expect(spec.target == .acceptsStableTarget)
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_mixer", command: "set_input_bus_verified"))
        let f = try Fixture(), cache = StateCache(), registry = TargetRegistry(), router = ChannelRouter()
        let channel = f.f.channel(logicOverride: f.runtime)
        await router.register(channel)
        let poller = StatePoller(axChannel: channel, cache: cache,
            runtime: .init(hasVisibleWindow: { true }, dialogPresent: { false }, blockingDialogInfo: { nil },
                projectFileReader: .unavailable, keyboardFocus: { .notTextEditing }))
        #expect(await poller.refreshNow())
        let mixer = try await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router,
            targetRegistry: registry, fileReader: .unavailable)
        let rows = try #require(sharedJSONObject(sharedResourceText(mixer))?["strips"] as? [[String: Any]])
        var target: String?
        for reference in rows.compactMap({ $0["mixer_strip_ref"] as? String }) {
            if let physical = await registry.resolve(.init(rawValue: reference))?.physicalMixerStrip,
               CFEqual(physical.strip, f.f.strips[0]) { target = reference }
        }
        let reference = try #require(target)
        let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry, poller: poller,
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: LogicMutationGate(),
            liveTrackNames: { [0: "A", 1: "B"] }, projectFileReader: .unavailable)
        let params: [String: Value] = ["target_ref": .string(reference),
            "destination": .object(["kind": "bus", "number": .int(1)]),
            "expected_current": .object(["kind": "bus", "number": .int(256)]), "replace_existing": .bool(true)]
        let result = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "set_input_bus_verified",
            commandParams: params, mutationGate: dependencies.mutationGate) {
            await FeatureFlags.withAdr002TargetRefForTests(true) { await handler(dependencies, params) }
        }
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["state"] as? String == "A", "Actual registered response: \(body)")
        #expect(f.leafPresses == [1])
        #expect(f.open == nil)
        #expect(dependencies.mutationGate?.currentOperation() == nil)
        for extra in ["track", "index", "values"] {
            var invalid = params; invalid[extra] = .int(0)
            let rejected = await FeatureFlags.withAdr002TargetRefForTests(true) { await handler(dependencies, invalid) }
            #expect(sharedJSONObject(sharedToolText(rejected))?["state"] as? String == "C")
            #expect(f.leafPresses == [1])
        }
    }
}
