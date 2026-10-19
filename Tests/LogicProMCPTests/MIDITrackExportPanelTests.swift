@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@MainActor
private struct MIDIExportPanelFixture {
    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let window: AXUIElement
    let panel: AXUIElement
    let runtime: AXLogicProElements.Runtime
    let keyboard: MIDITrackExportPanel.Keyboard

    init(destination: URL, fault: String = "") {
        let b = builder
        app = b.element(0); window = b.element(1); panel = b.element(8)
        let app = app, window = window, panel = panel
        let bar = b.element(2), file = b.element(3), menu = b.element(4)
        let export = b.element(5), submenu = b.element(6), leaf = b.element(7)
        let name = b.element(9), save = b.element(10), cancel = b.element(11)
        let browser = b.element(12), list = b.element(13), group = b.element(14), folder = b.element(15)
        let go = b.element(16), path = b.element(17)
        for (element, role) in [(app, "AXApplication"), (window, "AXWindow"), (bar, "AXMenuBar"),
            (file, "AXMenuBarItem"), (menu, "AXMenu"), (export, "AXMenuItem"), (submenu, "AXMenu"),
            (leaf, "AXMenuItem"), (panel, "AXWindow"), (name, "AXTextField"), (save, "AXButton"),
            (cancel, "AXButton"), (browser, "AXBrowser"), (list, "AXList"), (group, "AXGroup"),
            (folder, "AXTextField"), (go, "AXSheet"), (path, "AXTextField")] { b.setRole(element, role) }
        for (element, id) in [(panel, "save-panel"), (name, "saveAsNameTextField"), (save, "OKButton"),
            (cancel, "CancelButton"), (browser, "ColumnView"), (go, "GoToWindow"), (path, "PathTextField")] {
            b.setAttribute(element, kAXIdentifierAttribute as String, id)
        }
        b.setAttribute(window, kAXDocumentAttribute as String, "file:///fixture.logicx/")
        b.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole)
        b.setAttribute(window, kAXModalAttribute as String, kCFBooleanFalse!)
        b.setAttribute(panel, kAXSubroleAttribute as String, kAXDialogSubrole)
        b.setAttribute(panel, kAXModalAttribute as String, kCFBooleanTrue!)
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
        b.setAttribute(app, kAXFocusedWindowAttribute as String, window)
        b.setAttribute(app, "AXMenuBar", bar)
        b.setAttribute(app, kAXWindowsAttribute as String, fault == "preexisting" ? [window, panel] : [window])
        b.setChildren(bar, [file]); b.setChildren(file, [menu]); b.setChildren(menu, [export])
        b.setChildren(export, [submenu]); b.setChildren(submenu, [leaf])
        b.setAttribute(file, kAXTitleAttribute as String, "File")
        b.setAttribute(export, kAXTitleAttribute as String, "Export")
        b.setAttribute(leaf, kAXTitleAttribute as String, "All MIDI Tracks as MIDI File…")
        for element in [file, export, leaf, save, cancel] { b.setAttribute(element, kAXEnabledAttribute as String, true) }
        b.setChildren(panel, [name, save, cancel, browser]); b.setChildren(browser, [list])
        b.setChildren(list, [group]); b.setChildren(group, [folder]); b.setChildren(go, [path])
        if fault == "unreadable_identifier" || fault == "unreadable_role" {
            let unread = b.element(18)
            b.setRole(unread, "AXButton")
            b.setChildren(panel, [name, save, cancel, browser, unread])
        }
        if fault == "deeper_selected" {
            let nestedList = b.element(19), nestedGroup = b.element(20), nestedFolder = b.element(21)
            b.setRole(nestedList, "AXList"); b.setRole(nestedGroup, "AXGroup"); b.setRole(nestedFolder, "AXTextField")
            b.setChildren(browser, [list, nestedList]); b.setChildren(nestedList, [nestedGroup]); b.setChildren(nestedGroup, [nestedFolder])
            b.setAttribute(nestedList, kAXSelectedChildrenAttribute as String, [nestedGroup])
            b.setAttribute(nestedFolder, kAXURLAttribute as String, destination.deletingLastPathComponent().appendingPathComponent("child", isDirectory: true) as NSURL)
        }
        b.setAttribute(list, kAXSelectedChildrenAttribute as String, [group])
        b.setAttribute(folder, kAXURLAttribute as String, (fault == "wrong_folder" ? URL(fileURLWithPath: "/other") : destination.deletingLastPathComponent()) as NSURL)
        b.setAttribute(name, kAXValueAttribute as String, "initial.mid")
        b.setAttribute(path, kAXValueAttribute as String, "")
        runtime = b.makeLogicRuntime(appElement: app, attributeValueHandler: { element, attribute in
            if fault == "replaced_go", CFEqual(element, path), attribute == kAXValueAttribute as String,
               (b.attributeValue(path, attribute) as? String ?? "") != "" {
                let replacement = b.element(23), replacementPath = b.element(24)
                b.setRole(replacement, "AXSheet"); b.setRole(replacementPath, "AXTextField")
                b.setAttribute(replacement, kAXIdentifierAttribute as String, "GoToWindow")
                b.setAttribute(replacementPath, kAXIdentifierAttribute as String, "PathTextField")
                b.setChildren(replacement, [replacementPath])
                b.setChildren(panel, [name, save, cancel, browser, replacement])
            }
            if fault == "late_panel_replaced", CFEqual(element, save), attribute == kAXEnabledAttribute as String {
                b.setAttribute(app, kAXWindowsAttribute as String, [window, b.element(25)])
            }
            return nil
        }, attributeValueResultHandler: { element, attribute in
            if (fault == "retiring_go" || fault == "persistent_retiring_go"), CFEqual(element, go), attribute == kAXRoleAttribute as String,
               b.attributeValue(app, "returns") as? Int == 1,
               (fault == "persistent_retiring_go" || b.attributeValue(app, "retired_read") == nil) {
                b.setAttribute(app, "retired_read", true)
                if fault == "retiring_go" { b.setChildren(panel, [name, save, cancel, browser]) }
                return .failure(.init(raw: AXError.invalidUIElement.rawValue))
            }
            if fault == "unreadable_role", CFEqual(element, b.element(18)), attribute == kAXRoleAttribute as String {
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            }
            if fault == "unreadable_identifier", CFEqual(element, b.element(18)), attribute == kAXIdentifierAttribute as String {
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            }
            return nil
        }, setAttributeHandler: nil, performActionHandler: { element, action in
            if CFEqual(element, leaf), action == kAXPickAction as String {
                b.setAttribute(app, kAXWindowsAttribute as String, [window, panel])
                b.setAttribute(app, kAXFocusedWindowAttribute as String, panel)
                if fault == "changed_document" { b.setAttribute(window, kAXDocumentAttribute as String, "file:///other.logicx/") }
            }
            if CFEqual(element, save) || CFEqual(element, cancel) {
                b.setAttribute(element, "presses", (b.attributeValue(element, "presses") as? Int ?? 0) + 1)
                b.setAttribute(app, kAXWindowsAttribute as String, [window])
            }
            return true
        })
        keyboard = .init(post: { key, _ in
            let extras = fault == "unreadable_identifier" ? [b.element(18)] : []
            if key == 5 { b.setChildren(panel, [name, save, cancel, browser, go] + extras) }
            if key == 36 {
                b.setAttribute(app, "returns", (b.attributeValue(app, "returns") as? Int ?? 0) + 1)
                b.setChildren(panel, [name, save, cancel, browser] + extras)
                if fault == "retiring_go" || fault == "persistent_retiring_go" { b.setChildren(panel, [name, save, cancel, browser, go]) }
                if fault == "replaced_panel" { b.setAttribute(app, kAXWindowsAttribute as String, [window, b.element(20)]) }
                if fault == "other_focused_window" {
                    b.setAttribute(app, kAXWindowsAttribute as String, [window, panel, b.element(22)])
                    b.setAttribute(app, kAXMainWindowAttribute as String, b.element(22))
                }
            }
            return fault != "keyboard_refused"
        })
    }

    func driver() -> MIDITrackExportPanel {
        .init(window: window, document: "file:///fixture.logicx/", runtime: runtime,
              keyboard: keyboard, permittingAction: { true }, sleep: { _ in })
    }

    var savePresses: Int { builder.attributeValue(builder.element(10), "presses") as? Int ?? 0 }
    var cancelPresses: Int { builder.attributeValue(builder.element(11), "presses") as? Int ?? 0 }
}

@MainActor @Test func midiExportPanelWaitsForARetiringGoToSheetWithoutRepeatingActions() async throws {
    let temporary = try ExportTemporaryFiles.temporaryExportFile()
    defer { ExportTemporaryFiles.cleanupTemporaryExportFile(temporary) }
    let f = MIDIExportPanelFixture(destination: temporary.fileURL, fault: "retiring_go")
    try await f.driver().exportAll(to: temporary.fileURL)
    #expect(f.savePresses == 1 && f.cancelPresses == 0)
    #expect(f.builder.attributeValue(f.app, "returns") as? Int == 1)
}

@MainActor @Test func midiExportPanelUsesFolderThenBasenameAndSavesOnlyOnce() async throws {
    let temporary = try ExportTemporaryFiles.temporaryExportFile()
    defer { ExportTemporaryFiles.cleanupTemporaryExportFile(temporary) }
    let f = MIDIExportPanelFixture(destination: temporary.fileURL)
    let driver = f.driver()
    try await driver.exportAll(to: temporary.fileURL)
    #expect(f.savePresses == 1 && f.cancelPresses == 0)
    #expect(f.builder.attributeValue(f.builder.element(17), kAXValueAttribute as String) as? String == temporary.directoryURL.path)
    #expect(f.builder.attributeValue(f.builder.element(9), kAXValueAttribute as String) as? String == temporary.fileURL.lastPathComponent)
    do { try await driver.exportAll(to: temporary.fileURL); Issue.record("Repeated export was admitted") } catch { }
    #expect(f.savePresses == 1)
}

@MainActor @Test(arguments: ["preexisting", "wrong_folder", "changed_document", "replaced_panel", "keyboard_refused", "unreadable_identifier", "unreadable_role", "persistent_retiring_go", "deeper_selected", "other_focused_window", "replaced_go", "late_panel_replaced"])
func midiExportPanelRefusesWrongOwnershipAndDestination(fault: String) async throws {
    let temporary = try ExportTemporaryFiles.temporaryExportFile()
    defer { ExportTemporaryFiles.cleanupTemporaryExportFile(temporary) }
    let f = MIDIExportPanelFixture(destination: temporary.fileURL, fault: fault)
    do {
        try await f.driver().exportAll(to: temporary.fileURL)
        Issue.record("An unqualified panel or folder was saved")
    } catch {
        if fault == "unreadable_role" {
            #expect(error as? MIDITrackExportPanel.Failure == .unavailable("save_panel_ready:panel_attribute_unreadable:AXRole:\(AXError.cannotComplete.rawValue)"))
        }
    }
    #expect(f.savePresses == 0)
    if fault == "replaced_go" { #expect(f.builder.attributeValue(f.app, "returns") == nil) }
    if fault == "persistent_retiring_go" { #expect(f.builder.attributeValue(f.app, "returns") as? Int == 1) }
    if fault == "preexisting" || fault == "replaced_panel" { #expect(f.cancelPresses == 0) }
}

@MainActor @Test func midiExportPanelResolvesActualFileReferenceDirectoryURLs() async throws {
    let temporary = try ExportTemporaryFiles.temporaryExportFile()
    defer { ExportTemporaryFiles.cleanupTemporaryExportFile(temporary) }
    let reference = try #require((temporary.directoryURL as NSURL).fileReferenceURL())
    let fresh = try #require(NSURL(string: reference.absoluteString))
    let f = MIDIExportPanelFixture(destination: temporary.fileURL)
    f.builder.setAttribute(f.builder.element(15), kAXURLAttribute as String, fresh)
    let ancestorList = f.builder.element(19), ancestorGroup = f.builder.element(20), ancestorField = f.builder.element(21)
    f.builder.setRole(ancestorList, "AXList"); f.builder.setRole(ancestorGroup, "AXGroup"); f.builder.setRole(ancestorField, "AXTextField")
    f.builder.setChildren(f.builder.element(12), [ancestorList, f.builder.element(13)])
    f.builder.setChildren(ancestorList, [ancestorGroup]); f.builder.setChildren(ancestorGroup, [ancestorField])
    f.builder.setAttribute(ancestorList, kAXSelectedChildrenAttribute as String, [ancestorGroup])
    f.builder.setAttribute(ancestorField, kAXURLAttribute as String, URL(fileURLWithPath: "/private", isDirectory: true) as NSURL)
    try await f.driver().exportAll(to: temporary.fileURL)
    #expect(f.savePresses == 1)
}
