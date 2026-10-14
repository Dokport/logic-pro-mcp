@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#304 target-bound Tempo List resource")
struct Issue304TempoMapResourceTests {
    @Test func actualTempoListProducerIsPubliclyReadableWithoutOpeningOrWriting() async throws {
        let fixture = TempoResourceFixture()
        let router = await fixture.router()
        let result = try await ResourceHandlers.read(uri: "logic://tempo/map", cache: StateCache(), router: router)
        let body = try resourceBody(result)
        #expect(body["source"] as? String == "ax_live")
        let readable = try #require(body["readable"] as? Bool)
        #expect(readable)
        let complete = try #require(body["complete"] as? Bool)
        #expect(!complete)
        let data = try #require(body["data"] as? [String: Any])
        #expect(data["reportedEventCount"] as? Int == 1)
        let events = try #require(data["events"] as? [[String: Any]])
        #expect(events.count == 1)
        #expect(events.first?["position"] as? String == "1 1 1 1 ")
        #expect(events.first?["tempo"] as? Double == 120)
        #expect(events.first?["smpte"] as? String == "01:00:00:00.00")
        #expect(fixture.rowReads == 2)
        #expect(fixture.builder.actionCalls.isEmpty)
        #expect(fixture.builder.setCalls.isEmpty)
        #expect(ResourceProvider.resources.contains { $0.uri == "logic://tempo/map" })
    }

    @Test(arguments: ["closed", "foreign_document", "missing_document", "malformed_document",
        "unreadable_document", "late_document", "late_arrange_document", "late_final_arrange", "late_arrange_cf", "late_pid", "late_window_removal",
        "ambiguous", "foreign_competitor", "count_mismatch", "malformed_tempo", "late_permission"])
    func unknownOrChangedTempoListNeverPublishesCachedOrDefaultEvents(mode: String) async throws {
        let fixture = TempoResourceFixture(mode: mode)
        let result = try await ResourceHandlers.read(uri: "logic://tempo/map", cache: StateCache(),
            router: await fixture.router())
        let body = try resourceBody(result)
        #expect(body["state"] as? String == "C")
        #expect(body["error"] as? String == "readback_unavailable")
        let readable = try #require(body["readable"] as? Bool)
        #expect(!readable)
        #expect(body["data"] is NSNull)
        #expect(fixture.builder.actionCalls.isEmpty)
        #expect(fixture.builder.setCalls.isEmpty)
        if mode.hasPrefix("late_") { #expect(fixture.rowReads == 2) }
        if mode == "late_final_arrange" { #expect(fixture.finalMutations == 1) }
    }

    @Test func observedEmptyTempoListRemainsDistinctFromUnavailableAndGlobalCompletion() async throws {
        let fixture = TempoResourceFixture(mode: "empty")
        let body = try resourceBody(try await ResourceHandlers.read(uri: "logic://tempo/map",
            cache: StateCache(), router: await fixture.router()))
        let readable = try #require(body["readable"] as? Bool)
        #expect(readable)
        let complete = try #require(body["complete"] as? Bool)
        #expect(!complete)
        let data = try #require(body["data"] as? [String: Any])
        #expect(data["reportedEventCount"] as? Int == 0)
        let events = try #require(data["events"] as? [[String: Any]])
        #expect(events.isEmpty)
        #expect(fixture.rowReads == 2)
        #expect(fixture.builder.actionCalls.isEmpty)
    }

    private func resourceBody(_ result: ReadResource.Result) throws -> [String: Any] {
        guard let text = result.contents.first?.text else {
            throw MCPError.internalError("No Tempo Map resource body")
        }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

private final class TempoResourceFixture: @unchecked Sendable {
    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let arrange: AXUIElement
    let tempoWindow: AXUIElement
    let table: AXUIElement
    let count: AXUIElement
    var rowReads = 0
    var finalMutations = 0
    var trusted = true
    var pid: pid_t? = 4242
    let mode: String
    let document = "file:///tmp/tempo-resource.logicx/"

    init(mode: String = "healthy") {
        self.mode = mode
        app = builder.element(304_000)
        arrange = builder.element(304_001)
        tempoWindow = builder.element(304_002)
        table = builder.element(304_003)
        count = builder.element(304_004)
        let rail = builder.element(304_005)
        let menu = builder.element(304_006)
        let titles = ["File", "Edit", "Track"].enumerated().map { index, title in
            let item = builder.element(304_010 + index)
            builder.setRole(item, kAXMenuBarItemRole as String)
            builder.setAttribute(item, kAXTitleAttribute as String, title)
            return item
        }
        builder.setRole(app, kAXApplicationRole as String)
        builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, tempoWindow])
        builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        builder.setAttribute(app, kAXMenuBarAttribute as String, menu)
        builder.setRole(menu, kAXMenuBarRole as String)
        builder.setChildren(menu, titles)
        for window in [arrange, tempoWindow] {
            builder.setRole(window, kAXWindowRole as String)
            builder.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
            builder.setAttribute(window, kAXDocumentAttribute as String, document)
        }
        builder.setAttribute(arrange, kAXTitleAttribute as String, "tempo-resource - Tracks")
        builder.setRole(rail, kAXListRole as String)
        builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(rail, [])
        builder.setChildren(arrange, [rail])
        builder.setRole(table, kAXTableRole as String)
        builder.setRole(count, kAXStaticTextRole as String)
        builder.setAttribute(count, kAXDescriptionAttribute as String, AXLocalePolicy.tempoListNumberOfItemsLabel.canonical)
        builder.setAttribute(count, kAXValueAttribute as String, "1 event")
        builder.setChildren(tempoWindow, [table, count])
        let row = builder.element(304_020)
        builder.setRole(row, kAXRowRole as String)
        let cells = ["1 1 1 1 ", "120", "01:00:00:00.00"].enumerated().map { index, description in
            let cell = builder.element(304_021 + index)
            let group = builder.element(304_031 + index)
            builder.setRole(cell, kAXCellRole as String)
            builder.setRole(group, kAXGroupRole as String)
            builder.setAttribute(group, kAXDescriptionAttribute as String, description)
            builder.setChildren(group, [])
            builder.setChildren(cell, [group])
            return cell
        }
        builder.setChildren(row, cells)
        builder.setChildren(table, [row])
        builder.setAttribute(table, "AXRows", [row])
        builder.setChildren(count, [])
        if mode == "closed" { builder.setAttribute(app, kAXWindowsAttribute as String, [arrange]) }
        if mode == "foreign_document" { builder.setAttribute(tempoWindow, kAXDocumentAttribute as String, "file:///tmp/foreign.logicx/") }
        if mode == "missing_document" { builder.removeAttribute(tempoWindow, kAXDocumentAttribute as String) }
        if mode == "malformed_document" { builder.setAttribute(tempoWindow, kAXDocumentAttribute as String, NSNumber(value: 1)) }
        if mode == "count_mismatch" { builder.setAttribute(count, kAXValueAttribute as String, "2 events") }
        if mode == "malformed_tempo" { builder.setAttribute(builder.element(304_032), kAXDescriptionAttribute as String, "nan") }
        if mode == "empty" {
            builder.setChildren(table, [])
            builder.setAttribute(table, "AXRows", [] as [AXUIElement])
            builder.setAttribute(count, kAXValueAttribute as String, "0 events")
        }
        if mode == "ambiguous" || mode == "foreign_competitor" {
            let competing = builder.element(304_040)
            builder.setRole(competing, kAXWindowRole as String)
            builder.setAttribute(competing, kAXDocumentAttribute as String,
                mode == "foreign_competitor" ? "file:///tmp/foreign.logicx/" : document)
            // Both windows structurally offer the existing table/count; a foreign
            // candidate must not be filtered to turn ambiguous discovery into success.
            builder.setChildren(competing, [table, count])
            builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, tempoWindow, competing])
        }
    }

    func router() async -> ChannelRouter {
        let base = builder.makeLogicRuntime(appElement: app,
            attributeValueHandler: { [self] element, attribute in
                if CFEqual(element, table), attribute == "AXRows" {
                    rowReads += 1
                    if rowReads == 2 {
                        if mode == "late_document" { builder.setAttribute(tempoWindow, kAXDocumentAttribute as String, "file:///tmp/foreign.logicx/") }
                        if mode == "late_arrange_document" { builder.setAttribute(arrange, kAXDocumentAttribute as String, "file:///tmp/foreign.logicx/") }
                        if mode == "late_arrange_cf" {
                            let replacement = builder.element(304_050)
                            builder.setRole(replacement, kAXWindowRole as String)
                            builder.setAttribute(replacement, kAXTitleAttribute as String, "tempo-resource - Tracks")
                            builder.setAttribute(replacement, kAXDocumentAttribute as String, document)
                            builder.setChildren(replacement, [builder.element(304_005)])
                            builder.setAttribute(app, kAXWindowsAttribute as String, [replacement, tempoWindow])
                        }
                        if mode == "late_pid" { pid = 4243 }
                        if mode == "late_window_removal" { builder.setAttribute(app, kAXWindowsAttribute as String, [arrange]) }
                        if mode == "late_permission" { trusted = false }
                    }
                }
                return nil
            }, attributeValueResultHandler: { [self] element, attribute in
                if mode == "late_final_arrange", rowReads == 2, finalMutations == 0,
                   CFEqual(element, tempoWindow), attribute == kAXDocumentAttribute as String {
                    finalMutations += 1
                    builder.setAttribute(arrange, kAXDocumentAttribute as String, "file:///tmp/foreign.logicx/")
                    return .success(document as NSString)
                }
                if mode == "unreadable_document", CFEqual(element, tempoWindow), attribute == kAXDocumentAttribute as String {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                return nil
            }, setAttributeHandler: nil, performActionHandler: nil)
        let runtime = AXLogicProElements.Runtime(logicProPID: { [self] in pid }, ax: base.ax,
            executeAppleScript: { _ in .error("No script is authorized by this read-only fixture") },
            onScreenWindowList: { [] }, postPopupMenuEscape: {})
        let channel = AccessibilityChannel(runtime: .axBacked(isTrusted: { [self] in trusted },
            isLogicProRunning: { true }, hasVisibleWindow: { true }, logicRuntime: runtime))
        let router = ChannelRouter()
        await router.register(channel)
        return router
    }
}
