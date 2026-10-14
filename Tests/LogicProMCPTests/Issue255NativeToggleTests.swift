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

@Test(arguments: ["off", "on", "missing", "unreadable", "text", "nonbinary", "fractional", "nonfinite",
                  "duplicate", "wrong_role", "wrong_owner", "false_friend", "customization_popover"])
func autopunchResourceRequiresOneObservedOwnBinaryCheckbox(shape: String) async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_610), window = builder.element(25_611), bar = builder.element(25_612)
    let play = builder.element(25_613), record = builder.element(25_614), autopunch = builder.element(25_615)
    let duplicate = builder.element(25_616), foreign = builder.element(25_617)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [bar, foreign])
    builder.setAttribute(bar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setAttribute(foreign, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(foreign, kAXDescriptionAttribute as String, "Inspector")
    builder.setChildren(bar, [play, record] + (["missing", "wrong_owner", "customization_popover"].contains(shape) ? [] : [autopunch])
        + (shape == "duplicate" ? [duplicate] : []))
    if shape == "wrong_owner" { builder.setChildren(foreign, [autopunch]) }
    if shape == "customization_popover" {
        let popover = builder.element(25_618)
        builder.setAttribute(popover, kAXRoleAttribute as String, "AXPopover")
        builder.setChildren(popover, [autopunch])
        builder.setChildren(bar, [play, record, popover])
    }
    // Independent own-control spelling from Logic's existing transport-button row;
    // these injected cases do not establish native visibility or locale qualification.
    let title = shape == "false_friend" ? "Autopunch Settings" : "Autopunch"
    for (element, label) in [(play, "Play"), (record, "Record"), (autopunch, title), (duplicate, "Autopunch")] {
        builder.setAttribute(element, kAXRoleAttribute as String,
            element == autopunch && shape == "wrong_role" ? kAXButtonRole as String : kAXCheckBoxRole as String)
        builder.setAttribute(element, kAXTitleAttribute as String, label)
        builder.setAttribute(element, kAXDescriptionAttribute as String, label)
        if element != autopunch || shape != "unreadable" {
            builder.setAttribute(element, kAXValueAttribute as String, NSNumber(value: element == autopunch && shape == "on"))
        }
    }
    switch shape {
    case "text": builder.setAttribute(autopunch, kAXValueAttribute as String, "1")
    case "nonbinary": builder.setAttribute(autopunch, kAXValueAttribute as String, NSNumber(value: 2))
    case "fractional": builder.setAttribute(autopunch, kAXValueAttribute as String, NSNumber(value: 0.5))
    case "nonfinite": builder.setAttribute(autopunch, kAXValueAttribute as String, NSNumber(value: Double.nan))
    default: break
    }
    let router = ChannelRouter()
    await router.register(issue255Channel(logicRuntime: builder.makeLogicRuntime(appElement: app)))
    let result = try await ResourceHandlers.read(uri: "logic://transport/state", cache: StateCache(), router: router)
    let text = try #require(result.contents.first?.text)
    let envelope = try #require(sharedJSONObject(text))
    let data = try #require(envelope["data"] as? [String: Any])
    let state = try #require(data["state"] as? [String: Any])
    let playing = try #require(state["isPlaying"] as? Bool), recording = try #require(state["isRecording"] as? Bool)
    #expect(!playing)
    #expect(!recording)
    if shape == "off" || shape == "on" {
        let observed = try #require(state["isAutopunchEnabled"] as? Bool)
        if shape == "on" { #expect(observed) } else { #expect(!observed) }
    } else { #expect(!state.keys.contains("isAutopunchEnabled")) }
}

@Test func autopunchWriterDoesNotPressTheLoneCustomizationVisibilityOption() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_620), window = builder.element(25_621), bar = builder.element(25_622)
    let play = builder.element(25_623), record = builder.element(25_624)
    let popover = builder.element(25_625), option = builder.element(25_626)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [bar])
    builder.setAttribute(bar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setAttribute(popover, kAXRoleAttribute as String, "AXPopover")
    builder.setChildren(bar, [play, record, popover]); builder.setChildren(popover, [option])
    for (element, label) in [(play, "Play"), (record, "Record"), (option, "Autopunch")] {
        builder.setAttribute(element, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(element, kAXTitleAttribute as String, label)
        builder.setAttribute(element, kAXValueAttribute as String, NSNumber(value: 0))
    }
    final class Effects: @unchecked Sendable { var presses = 0 }
    let effects = Effects()
    let runtime = builder.makeLogicRuntime(appElement: app, setAttributeHandler: nil, performActionHandler: { element, action in
        if CFEqual(element, option), action == kAXPressAction as String {
            effects.presses += 1
            builder.setAttribute(option, kAXValueAttribute as String, NSNumber(value: 1))
            return true
        }
        Issue.record("No customization option or other control may be actuated"); return false
    })
    let result = await issue255Channel(logicRuntime: runtime).execute(operation: "transport.toggle_autopunch", params: [:])
    let body = try #require(issue255Object(result.message))
    #expect(effects.presses == 0)
    #expect(body["state"] as? String == "C")
    let value = try #require(builder.attributeValue(option, kAXValueAttribute as String) as? NSNumber)
    #expect(value.doubleValue == 0)
}

@Test(arguments: ["missing_value", "text", "nonbinary", "fractional", "duplicate", "wrong_role"])
func autopunchWriterRequiresOneOwnBinaryBaseline(shape: String) async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_630), window = builder.element(25_631), bar = builder.element(25_632)
    let control = builder.element(25_633), duplicate = builder.element(25_634)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [bar])
    builder.setAttribute(bar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(bar, [control] + (shape == "duplicate" ? [duplicate] : []))
    for element in [control, duplicate] {
        builder.setAttribute(element, kAXRoleAttribute as String,
            shape == "wrong_role" ? kAXButtonRole as String : kAXCheckBoxRole as String)
        builder.setAttribute(element, kAXTitleAttribute as String, "Autopunch")
        builder.setAttribute(element, kAXValueAttribute as String, NSNumber(value: 0))
    }
    switch shape {
    case "missing_value": builder.removeAttribute(control, kAXValueAttribute as String)
    case "text": builder.setAttribute(control, kAXValueAttribute as String, "1")
    case "nonbinary": builder.setAttribute(control, kAXValueAttribute as String, NSNumber(value: 2))
    case "fractional": builder.setAttribute(control, kAXValueAttribute as String, NSNumber(value: 0.5))
    default: break
    }
    final class Effects: @unchecked Sendable { var presses = 0 }
    let effects = Effects()
    let runtime = builder.makeLogicRuntime(appElement: app, setAttributeHandler: nil, performActionHandler: { _, _ in
        effects.presses += 1
        return true
    })
    let result = await issue255Channel(logicRuntime: runtime).execute(operation: "transport.toggle_autopunch", params: [:])
    let body = try #require(issue255Object(result.message))
    #expect(effects.presses == 0)
    #expect(body["state"] as? String == "C")
}

@Test(arguments: ["reader", "writer"])
func autopunchUnreadableDirectCompetitorCannotEstablishUniqueness(surface: String) async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_640), window = builder.element(25_641), bar = builder.element(25_642)
    let play = builder.element(25_643), record = builder.element(25_644)
    let control = builder.element(25_645), competitor = builder.element(25_646)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [bar])
    builder.setAttribute(bar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(bar, [play, record, control, competitor])
    for (element, title) in [(play, "Play"), (record, "Record"), (control, "Autopunch"), (competitor, "Autopunch")] {
        builder.setAttribute(element, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(element, kAXTitleAttribute as String, title)
        builder.setAttribute(element, kAXValueAttribute as String, NSNumber(value: 0))
    }
    final class Effects: @unchecked Sendable { var presses = 0; var labelFailures = 0 }
    let effects = Effects()
    let runtime = builder.makeLogicRuntime(appElement: app, attributeValueHandler: { element, attribute in
        if CFEqual(element, competitor), [kAXTitleAttribute as String, kAXDescriptionAttribute as String].contains(attribute) {
            effects.labelFailures += 1
            return .some(nil)
        }
        return nil
    }, attributeValueResultHandler: { element, attribute in
        if CFEqual(element, competitor), [kAXTitleAttribute as String, kAXDescriptionAttribute as String].contains(attribute) {
            effects.labelFailures += 1
            return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
        }
        return nil
    }, setAttributeHandler: nil, performActionHandler: { element, action in
        guard CFEqual(element, control), action == kAXPressAction as String else { return false }
        effects.presses += 1
        builder.setAttribute(control, kAXValueAttribute as String, NSNumber(value: 1))
        return true
    })
    let channel = issue255Channel(logicRuntime: runtime)
    if surface == "reader" {
        let router = ChannelRouter(); await router.register(channel)
        let result = try await ResourceHandlers.read(uri: "logic://transport/state", cache: StateCache(), router: router)
        let text = try #require(result.contents.first?.text)
        let envelope = try #require(sharedJSONObject(text))
        let data = try #require(envelope["data"] as? [String: Any])
        let state = try #require(data["state"] as? [String: Any])
        #expect(!state.keys.contains("isAutopunchEnabled"))
    } else {
        let result = await channel.execute(operation: "transport.toggle_autopunch", params: [:])
        let body = try #require(issue255Object(result.message))
        #expect(body["state"] as? String == "C")
    }
    #expect(effects.labelFailures > 0)
    #expect(effects.presses == 0)
}

@Test func autopunchPostPressCustodyLossDiscardsEarlierReadback() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_650), window = builder.element(25_651), bar = builder.element(25_652)
    let control = builder.element(25_653)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [bar])
    builder.setAttribute(bar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(bar, [control])
    builder.setAttribute(control, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(control, kAXTitleAttribute as String, "Autopunch")
    builder.setAttribute(control, kAXValueAttribute as String, NSNumber(value: 0))
    final class Effects: @unchecked Sendable { var presses = 0; var postReads = 0 }
    let effects = Effects()
    let runtime = builder.makeLogicRuntime(appElement: app, childrenHandler: { element in
        if CFEqual(element, bar), effects.presses > 0 {
            effects.postReads += 1
            return effects.postReads == 2 ? [] : [control]
        }
        return nil
    }, childrenResultHandler: { element in
        if CFEqual(element, bar), effects.presses > 0 {
            effects.postReads += 1
            if effects.postReads == 2 { return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)) }
        }
        return nil
    }, setAttributeHandler: nil, performActionHandler: { _, _ in effects.presses += 1; return true })
    let result = await issue255Channel(logicRuntime: runtime).execute(operation: "transport.toggle_autopunch", params: [:])
    let body = try #require(issue255Object(result.message))
    #expect(effects.presses == 1)
    #expect(effects.postReads == 2)
    #expect(body["state"] as? String == "B")
    #expect(body["reason"] as? String == "readback_unavailable")
    #expect(body["observed"] is NSNull)
}

@Test(arguments: ["replacement", "duplicate", "wrong_role"])
func autopunchPostPressReadbackCannotBorrowAnotherControl(shape: String) async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_660), window = builder.element(25_661), bar = builder.element(25_662)
    let control = builder.element(25_663), replacement = builder.element(25_664)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [bar])
    builder.setAttribute(bar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(bar, [control])
    for element in [control, replacement] {
        builder.setAttribute(element, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(element, kAXTitleAttribute as String, "Autopunch")
        builder.setAttribute(element, kAXValueAttribute as String, NSNumber(value: element == replacement ? 1 : 0))
    }
    final class Effects: @unchecked Sendable { var presses = 0 }
    let effects = Effects()
    let runtime = builder.makeLogicRuntime(appElement: app, setAttributeHandler: nil, performActionHandler: { element, action in
        guard CFEqual(element, control), action == kAXPressAction as String else { return false }
        effects.presses += 1
        switch shape {
        case "replacement": builder.setChildren(bar, [replacement])
        case "duplicate": builder.setChildren(bar, [control, replacement])
        default: builder.setAttribute(control, kAXRoleAttribute as String, kAXButtonRole as String)
        }
        return true
    })
    let result = await issue255Channel(logicRuntime: runtime).execute(operation: "transport.toggle_autopunch", params: [:])
    let body = try #require(issue255Object(result.message))
    #expect(effects.presses == 1)
    #expect(body["state"] as? String == "B")
    #expect(body["reason"] as? String == "readback_unavailable")
    #expect(body["observed"] is NSNull)
    let unchanged = try #require(builder.attributeValue(control, kAXValueAttribute as String) as? NSNumber)
    #expect(unchanged.doubleValue == 0)
}

@Test func autopunchOptionalReadbackPreservesLegacyAndFuturePayloadCompatibility() throws {
    var legacy = try #require(sharedJSONObject(String(decoding: try JSONEncoder().encode(TransportState()), as: UTF8.self)))
    legacy.removeValue(forKey: "isAutopunchEnabled")
    legacy["future_transport_observation"] = ["value": true]
    let decoded = try JSONDecoder().decode(TransportState.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.isAutopunchEnabled == nil)
    #expect(!decoded.isPlaying)
    #expect(!decoded.isRecording)
    #expect(decoded.tempo == 120)
    #expect(decoded.position == "1.1.1.1")
    let roundtrip = try #require(sharedJSONObject(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)))
    #expect(!roundtrip.keys.contains("isAutopunchEnabled"))
    #expect(!roundtrip.keys.contains("future_transport_observation"))
}

@Test(arguments: ["off", "on", "ko_off", "ko_on", "missing", "unreadable", "text", "mixed",
                  "fractional", "nonfinite", "duplicate", "wrong_role", "wrong_owner", "false_friend"])
func countInResourceRequiresOneObservedOwnBinaryCheckbox(shape: String) async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_590)
    let window = builder.element(25_591)
    let bar = builder.element(25_592)
    let play = builder.element(25_593)
    let record = builder.element(25_594)
    let countIn = builder.element(25_595)
    let duplicate = builder.element(25_596)
    let foreign = builder.element(25_597)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [bar, foreign])
    builder.setAttribute(bar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setAttribute(foreign, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(foreign, kAXDescriptionAttribute as String, "Inspector")
    builder.setChildren(bar, [play, record] + (["missing", "wrong_owner"].contains(shape) ? [] : [countIn])
        + (shape == "duplicate" ? [duplicate] : []))
    if shape == "wrong_owner" { builder.setChildren(foreign, [countIn]) }
    // Retained own Control Bar names, not a test expectation generated from the policy.
    let countInTitle = shape.hasPrefix("ko_") ? "카운트 인" : (shape == "false_friend" ? "Count In Settings" : "Count In")
    for (element, title) in [(play, "Play"), (record, "Record"), (countIn, countInTitle), (duplicate, "Count In")] {
        builder.setAttribute(element, kAXRoleAttribute as String,
            element == countIn && shape == "wrong_role" ? kAXButtonRole as String : kAXCheckBoxRole as String)
        builder.setAttribute(element, kAXTitleAttribute as String, title)
        builder.setAttribute(element, kAXDescriptionAttribute as String, title)
        if element != countIn || shape != "unreadable" {
            builder.setAttribute(element, kAXValueAttribute as String, NSNumber(value: element == countIn && ["on", "ko_on"].contains(shape)))
        }
    }
    switch shape {
    case "text": builder.setAttribute(countIn, kAXValueAttribute as String, "1")
    case "mixed": builder.setAttribute(countIn, kAXValueAttribute as String, NSNumber(value: 2))
    case "fractional": builder.setAttribute(countIn, kAXValueAttribute as String, NSNumber(value: 0.5))
    case "nonfinite": builder.setAttribute(countIn, kAXValueAttribute as String, NSNumber(value: Double.nan))
    default: break
    }
    let router = ChannelRouter()
    await router.register(issue255Channel(logicRuntime: builder.makeLogicRuntime(appElement: app)))
    let result = try await ResourceHandlers.read(uri: "logic://transport/state", cache: StateCache(), router: router)
    let text = try #require(result.contents.first?.text)
    let envelope = try #require(sharedJSONObject(text))
    let data = try #require(envelope["data"] as? [String: Any])
    let state = try #require(data["state"] as? [String: Any])
    let playing = try #require(state["isPlaying"] as? Bool)
    let recording = try #require(state["isRecording"] as? Bool)
    #expect(!playing)
    #expect(!recording)
    if ["off", "on", "ko_off", "ko_on"].contains(shape) {
        let observed = try #require(state["isCountInEnabled"] as? Bool)
        if ["on", "ko_on"].contains(shape) { #expect(observed) } else { #expect(!observed) }
    } else { #expect(!state.keys.contains("isCountInEnabled")) }
}

@Test(arguments: ["Metronome Click", "메트로놈 클릭"])
func measuredMetronomeClickCheckboxPublishesItsObservedState(metronomeLabel: String) async throws {
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
    // These own AXCheckBox descriptions/titles come from the retained EN and KO censuses,
    // not expectations generated from the policy bag being repaired.
    for (element, title) in [(play, "Play"), (record, "Record"), (metronome, metronomeLabel)] {
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

@Test func countInOptionalReadbackDecodesLegacyStateAndIgnoresUnrelatedFutureFields() throws {
    var legacy = try #require(sharedJSONObject(String(decoding: try JSONEncoder().encode(TransportState()), as: UTF8.self)))
    legacy.removeValue(forKey: "isCountInEnabled")
    legacy["future_transport_observation"] = ["value": true]
    let decoded = try JSONDecoder().decode(TransportState.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.isCountInEnabled == nil)
    #expect(!decoded.isPlaying)
    #expect(!decoded.isRecording)
    #expect(decoded.tempo == 120)
    #expect(decoded.position == "1.1.1.1")
    let roundtrip = try #require(sharedJSONObject(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)))
    #expect(!roundtrip.keys.contains("isCountInEnabled"))
    #expect(!roundtrip.keys.contains("future_transport_observation"))
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
