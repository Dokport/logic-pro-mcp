@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private let issue255NoMouseRuntime = AXMouseHelper.Runtime(
    postMouseEvent: { _, _, _ in false },
    postKeyEvent: { _ in false },
    postUnicodeScalar: { _ in false },
    sleepMicros: { _ in }
)

private func issue255Object(_ raw: String) -> [String: Any]? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func issue255Channel(
    logicRuntime: AXLogicProElements.Runtime
) -> AccessibilityChannel {
    AccessibilityChannel(runtime: .axBacked(
        isTrusted: { true },
        isLogicProRunning: { true },
        logicRuntime: logicRuntime,
        controlBarMouseRuntime: issue255NoMouseRuntime
    ))
}

@Test func issue255NativeTogglesRouteAccessibilityFirst() {
    #expect(ChannelRouter.routingTable["transport.toggle_count_in"]?.first == .accessibility)
    #expect(ChannelRouter.routingTable["edit.toggle_step_input"]?.first == .accessibility)
}

@Test(arguments: ["off", "on", "missing", "unreadable", "duplicate"])
func transportCycleEvidenceIsObservedRatherThanTheFalseDefault(shape: String) async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_560)
    let window = builder.element(25_561)
    let bar = builder.element(25_562)
    let play = builder.element(25_563)
    let record = builder.element(25_564)
    let cycle = builder.element(25_565)
    let duplicate = builder.element(25_566)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [bar])
    builder.setAttribute(bar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(bar, [play, record] + (shape == "missing" ? [] : [cycle])
        + (shape == "duplicate" ? [duplicate] : []))
    for (element, title) in [(play, "Play"), (record, "Record"), (cycle, "Cycle"), (duplicate, "Cycle")] {
        builder.setAttribute(element, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(element, kAXTitleAttribute as String, title)
        if element != cycle || shape != "unreadable" {
            builder.setAttribute(element, kAXValueAttribute as String, NSNumber(value: element == cycle && shape == "on"))
        }
    }
    let router = ChannelRouter()
    await router.register(issue255Channel(logicRuntime: builder.makeLogicRuntime(appElement: app)))
    let result = try await ResourceHandlers.read(uri: "logic://transport/state", cache: StateCache(), router: router)
    let text = try #require(result.contents.first?.text)
    let envelope = try #require(sharedJSONObject(text))
    let data = try #require(envelope["data"] as? [String: Any])
    let state = try #require(data["state"] as? [String: Any])
    let legacy = try #require(state["isCycleEnabled"] as? Bool)
    if shape == "on" { #expect(legacy) } else { #expect(!legacy) }
    if shape == "off" || shape == "on" {
        let observed = try #require(state["observedCycleEnabled"] as? Bool)
        if shape == "on" { #expect(observed) } else { #expect(!observed) }
    } else { #expect(!state.keys.contains("observedCycleEnabled")) }
}

@Test(arguments: ["slow", "unreadable", "missing"])
func transportResourceCarriesActualTempoWithoutReplacingTheLegacyDefault(shape: String) async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_570)
    let window = builder.element(25_571)
    let bar = builder.element(25_572)
    let play = builder.element(25_573)
    let record = builder.element(25_574)
    let groups = (0..<5).map { builder.element(25_575 + $0) }
    let slider = builder.element(25_580)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [bar])
    builder.setAttribute(bar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(bar, [play, record, groups[0]])
    for (element, title) in [(play, "Play"), (record, "Record")] {
        builder.setAttribute(element, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(element, kAXTitleAttribute as String, title)
        builder.setAttribute(element, kAXValueAttribute as String, NSNumber(value: false))
    }
    for (index, group) in groups.enumerated() {
        builder.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setChildren(group, index < groups.count - 1 ? [groups[index + 1]] : (shape == "missing" ? [] : [slider]))
    }
    builder.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(slider, kAXDescriptionAttribute as String, "Tempo")
    if shape == "slow" { builder.setAttribute(slider, kAXValueAttribute as String, NSNumber(value: 20)) }
    let router = ChannelRouter()
    await router.register(issue255Channel(logicRuntime: builder.makeLogicRuntime(appElement: app)))
    let result = try await ResourceHandlers.read(uri: "logic://transport/state", cache: StateCache(), router: router)
    let text = try #require(result.contents.first?.text)
    let envelope = try #require(sharedJSONObject(text))
    let data = try #require(envelope["data"] as? [String: Any])
    let state = try #require(data["state"] as? [String: Any])
    #expect(state["tempo"] as? Double == (shape == "slow" ? 20 : 120),
        "preserve actual tempo where read and the legacy default where it was not read")
    if shape == "slow" { #expect(envelope["observed_tempo"] as? Double == 20) }
    else { #expect(!envelope.keys.contains("observed_tempo")) }
}

@Test func measuredMetronomeClickCheckboxPublishesItsObservedState() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_550)
    let window = builder.element(25_551)
    let bar = builder.element(25_552)
    let play = builder.element(25_553)
    let record = builder.element(25_554)
    let metronome = builder.element(25_555)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [bar])
    builder.setAttribute(bar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(bar, [play, record, metronome])
    // The compound is the actual own AXCheckBox description/title in the retained EN census,
    // not an expectation generated from the policy bag being repaired.
    for (element, title) in [(play, "Play"), (record, "Record"), (metronome, "Metronome Click")] {
        builder.setAttribute(element, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(element, kAXTitleAttribute as String, title)
        builder.setAttribute(element, kAXDescriptionAttribute as String, title)
        builder.setAttribute(element, kAXValueAttribute as String, NSNumber(value: 0))
    }
    let channel = issue255Channel(logicRuntime: builder.makeLogicRuntime(appElement: app))
    let result = await channel.execute(operation: "transport.get_state", params: [:])
    #expect(result.isSuccess)
    let object = try #require(issue255Object(result.message))
    let metronomeEnabled = try #require(object["isMetronomeEnabled"] as? Bool)
    let playing = try #require(object["isPlaying"] as? Bool)
    let recording = try #require(object["isRecording"] as? Bool)
    #expect(!metronomeEnabled)
    #expect(!playing)
    #expect(!recording)
}

@Test func issue255CountInMatchesLogic123ControlBarTitle() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_500)
    let window = builder.element(25_501)
    let controlBar = builder.element(25_502)
    let countIn = builder.element(25_503)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [controlBar])
    builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(controlBar, [countIn])
    builder.setAttribute(countIn, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(countIn, kAXTitleAttribute as String, "Count In")
    builder.setAttribute(countIn, kAXValueAttribute as String, NSNumber(value: false))

    let logicRuntime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard element == countIn, action == kAXPressAction as String else { return false }
            builder.setAttribute(countIn, kAXValueAttribute as String, NSNumber(value: true))
            return true
        }
    )
    let channel = issue255Channel(logicRuntime: logicRuntime)

    let result = await channel.execute(operation: "transport.toggle_count_in", params: [:])

    #expect(result.isSuccess)
    let object = try #require(issue255Object(result.message))
    let v1 = try #require(object["verified"] as? Bool)
    #expect(v1)
    let v2 = try #require(object["observed"] as? Bool)
    #expect(v2)
    #expect(object["button"] as? String == "Count In")
}

@Test func japaneseCreatorStudioPlayUsesExactLocalizedCheckboxAndReadback() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_504)
    let window = builder.element(25_505)
    let controlBar = builder.element(25_506)
    let play = builder.element(25_507)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [controlBar])
    builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "コントロールバー")
    builder.setChildren(controlBar, [play])
    builder.setAttribute(play, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(play, kAXTitleAttribute as String, "再生")
    builder.setAttribute(play, kAXValueAttribute as String, NSNumber(value: false))

    let logicRuntime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard element == play, action == kAXPressAction as String else { return false }
            builder.setAttribute(play, kAXValueAttribute as String, NSNumber(value: true))
            return true
        }
    )
    let channel = issue255Channel(logicRuntime: logicRuntime)

    let result = await channel.execute(operation: "transport.play", params: [:])

    #expect(result.isSuccess)
    let object = try #require(issue255Object(result.message))
    #expect(object["state"] as? String == "A")
    let verified = try #require(object["verified"] as? Bool)
    let observed = try #require(object["observed"] as? Bool)
    #expect(verified)
    #expect(observed)
    #expect(object["button"] as? String == "Play")
}

@Test func issue255StepInputUsesWindowMenuAndVerifiesWindowState() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_510)
    let tracksWindow = builder.element(25_511)
    let stepInputWindow = builder.element(25_512)
    let menuBar = builder.element(25_513)
    let windowMenu = builder.element(25_514)
    let menu = builder.element(25_515)
    let showStepInput = builder.element(25_516)

    builder.setAttribute(app, kAXMainWindowAttribute as String, tracksWindow)
    builder.setAttribute(app, kAXWindowsAttribute as String, [tracksWindow])
    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setAttribute(tracksWindow, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(tracksWindow, kAXTitleAttribute as String, "Untitled - Tracks")
    builder.setAttribute(stepInputWindow, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(
        stepInputWindow,
        kAXTitleAttribute as String,
        "Untitled - Step Input Keyboard"
    )

    builder.setChildren(menuBar, [windowMenu])
    builder.setAttribute(windowMenu, kAXRoleAttribute as String, kAXMenuBarItemRole as String)
    builder.setAttribute(windowMenu, kAXTitleAttribute as String, "Window")
    builder.setChildren(windowMenu, [menu])
    builder.setAttribute(menu, kAXRoleAttribute as String, kAXMenuRole as String)
    builder.setChildren(menu, [showStepInput])
    builder.setAttribute(showStepInput, kAXRoleAttribute as String, kAXMenuItemRole as String)
    // Measured 2026-09-05: Logic 12.3 titles this item `Step Input Keyboard`, with no
// verb. The fixture said `Show Step Input Keyboard`, which is why this test passed
// while the operation was dead against the real application — a fixture that encodes
// the wrong contract tests the contract, not the product.
    builder.setAttribute(showStepInput, kAXTitleAttribute as String, "Step Input Keyboard")
    builder.setAttribute(showStepInput, kAXEnabledAttribute as String, NSNumber(value: true))

    let logicRuntime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard element == showStepInput, action == kAXPressAction as String else { return false }
            builder.setAttribute(app, kAXWindowsAttribute as String, [tracksWindow, stepInputWindow])
            return true
        }
    )
    let channel = issue255Channel(logicRuntime: logicRuntime)

    let result = await channel.execute(operation: "edit.toggle_step_input", params: [:])

    #expect(result.isSuccess)
    let object = try #require(issue255Object(result.message))
    let v1 = try #require(object["verified"] as? Bool)
    #expect(v1)
    let v2 = try #require(object["previous_open"] as? Bool)
    #expect(!v2)
    let v3 = try #require(object["observed_open"] as? Bool)
    #expect(v3)
    #expect(object["via"] as? String == "window-menu")
}
