@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@MainActor
private struct MIDIHoldFixture {
    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let window: AXUIElement
    let rail: AXUIElement
    let headers: [AXUIElement]
    let runtime: AXLogicProElements.Runtime
    let observation = MIDITrackFileExport.Observation(projectReference: "prj_current", projectPath: "/fixture.logicx",
        coverage: .complete, tracks: [.init(reference: "trk_target", name: "Target"), .init(reference: "trk_peer", name: "Peer")])

    var bindings: [AXTrackBinding.Binding] {
        headers.map { .init(window: window, header: $0, document: "file:///fixture.logicx/", runtime: runtime) }
    }

    init() {
        app = builder.element(0); window = builder.element(1); rail = builder.element(2)
        headers = [builder.element(3), builder.element(5)]
        builder.setRole(app, kAXApplicationRole as String)
        builder.setRole(window, kAXWindowRole as String)
        builder.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole)
        builder.setAttribute(window, kAXDocumentAttribute as String, "file:///fixture.logicx/")
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setRole(rail, kAXListRole as String)
        builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(window, [rail]); builder.setChildren(rail, headers)
        for (index, name) in ["Target", "Peer"].enumerated() {
            let field = builder.element(index == 0 ? 4 : 6)
            builder.setRole(headers[index], kAXLayoutItemRole as String)
            builder.setRole(field, kAXTextFieldRole as String)
            builder.setAttribute(field, kAXValueAttribute as String, name)
            builder.setChildren(headers[index], [field])
        }
        runtime = builder.makeLogicRuntime(appElement: app)
    }
}

@MainActor @Test func midiNativeHoldRetainsActualHeadersWithoutUIActions() throws {
    let fixture = MIDIHoldFixture()
    let acquired = MIDITrackNativeHold(observation: fixture.observation, bindings: fixture.bindings,
        runtime: fixture.runtime, permittingRead: { true })
    let hold = try #require(acquired)
    #expect(hold.isCurrent())
    #expect(fixture.builder.actionCalls.isEmpty && fixture.builder.setCalls.isEmpty)
}

@MainActor @Test func midiNativeHoldRejectsSameNameReplacementAndOtherDocumentWindow() throws {
    let fixture = MIDIHoldFixture()
    let acquired = MIDITrackNativeHold(observation: fixture.observation, bindings: fixture.bindings,
        runtime: fixture.runtime, permittingRead: { true })
    let hold = try #require(acquired)
    let replacement = fixture.builder.element(7), field = fixture.builder.element(8)
    fixture.builder.setRole(replacement, kAXLayoutItemRole as String)
    fixture.builder.setRole(field, kAXTextFieldRole as String)
    fixture.builder.setAttribute(field, kAXValueAttribute as String, "Target")
    fixture.builder.setChildren(replacement, [field])
    fixture.builder.setChildren(fixture.rail, [replacement, fixture.headers[1]])
    #expect(!hold.isCurrent())
    fixture.builder.setChildren(fixture.rail, fixture.headers)
    #expect(!hold.isCurrent(), "An observed native identity loss is terminal for this hold")
    let reacquired = MIDITrackNativeHold(observation: fixture.observation, bindings: fixture.bindings,
        runtime: fixture.runtime, permittingRead: { true })
    let next = try #require(reacquired)
    fixture.builder.setAttribute(fixture.app, kAXMainWindowAttribute as String, fixture.builder.element(9))
    #expect(!next.isCurrent())
    #expect(fixture.builder.actionCalls.isEmpty && fixture.builder.setCalls.isEmpty)
}

@MainActor @Test func midiNativeHoldRejectsUnboundDocumentOrLostReadPermission() {
    let fixture = MIDIHoldFixture()
    let refusedPermission = MIDITrackNativeHold(observation: fixture.observation, bindings: fixture.bindings,
        runtime: fixture.runtime, permittingRead: { false })
    #expect(refusedPermission == nil)
    fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///other.logicx/")
    let refusedDocument = MIDITrackNativeHold(observation: fixture.observation, bindings: fixture.bindings,
        runtime: fixture.runtime, permittingRead: { true })
    #expect(refusedDocument == nil)
    #expect(fixture.builder.actionCalls.isEmpty && fixture.builder.setCalls.isEmpty)
}

@MainActor @Test func midiNativeHoldDoesNotReconstructCaptureCustodyFromEqualNames() {
    let fixture = MIDIHoldFixture()
    let replacement = fixture.builder.element(7), field = fixture.builder.element(8)
    fixture.builder.setRole(replacement, kAXLayoutItemRole as String)
    fixture.builder.setRole(field, kAXTextFieldRole as String)
    fixture.builder.setAttribute(field, kAXValueAttribute as String, "Target")
    fixture.builder.setChildren(replacement, [field])
    fixture.builder.setChildren(fixture.rail, [replacement, fixture.headers[1]])
    let refused = MIDITrackNativeHold(observation: fixture.observation, bindings: fixture.bindings,
        runtime: fixture.runtime, permittingRead: { true })
    #expect(refused == nil)
    #expect(fixture.builder.actionCalls.isEmpty && fixture.builder.setCalls.isEmpty)
}
