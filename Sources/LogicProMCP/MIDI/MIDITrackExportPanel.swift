@preconcurrency import ApplicationServices
import Foundation
import CoreGraphics

/// Whole-project MIDI route. It changes neither region selection nor Cycle.
/// The caller owns acquisition and supplies the original project window.
@MainActor
final class MIDITrackExportPanel {
    struct Keyboard {
        var post: @MainActor (CGKeyCode, CGEventFlags) -> Bool

        static let production = Keyboard(post: { key, flags in
            let keys = CGEventChannel.Runtime.production
            guard keys.canPostEvents(), keys.isLogicFrontmost(),
                  let pid = keys.logicProPID(), keys.focusedApplicationPID() == pid else { return false }
            if key == 5 {
                // No input-source selection. Refuse an unverified command key
                // map; the subsequent GoToWindow observation proves delivery.
                guard let layout = keys.asciiCapableLayoutID(),
                      ["com.apple.keylayout.ABC", "com.apple.keylayout.US"].contains(layout),
                      keys.layoutLetter(layout, key) == "g" else { return false }
            }
            // This AppKit Save-panel route did not receive postToPid even
            // when that API returned true. Use the foreground event route only
            // after the caller checks the exact owned panel's keyboard focus.
            guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
            var events: [CGEvent] = []
            for spec in CGEventChannel.keyEventSequence(keyCode: key, flags: flags) {
                let event: CGEvent?
                switch spec.kind {
                case .keyDown, .keyUp:
                    event = CGEvent(keyboardEventSource: source, virtualKey: spec.keyCode, keyDown: spec.kind == .keyDown)
                case .flagsChanged:
                    event = CGEvent(source: source); event?.type = .flagsChanged
                }
                guard let event else { return false }
                event.flags = spec.flags; events.append(event)
            }
            guard keys.isLogicFrontmost(), keys.focusedApplicationPID() == pid else { return false }
            for event in events { event.post(tap: .cghidEventTap) }
            return true
        })
    }

    enum Failure: Error, Equatable {
        case unavailable(String)
    }

    private let window: AXUIElement
    private let document: String
    private let runtime: AXLogicProElements.Runtime
    private let keyboard: Keyboard
    private let permittingAction: @MainActor () -> Bool
    private let sleep: @MainActor (UInt64) async throws -> Void
    private var started = false

    init(window: AXUIElement, document: String, runtime: AXLogicProElements.Runtime = .production,
         keyboard: Keyboard = .production, permittingAction: @escaping @MainActor () -> Bool,
         sleep: @escaping @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.window = window; self.document = document; self.runtime = runtime
        self.keyboard = keyboard; self.permittingAction = permittingAction; self.sleep = sleep
    }

    func exportAll(to destination: URL) async throws {
        guard !started else { throw Failure.unavailable("export_already_attempted") }
        started = true
        guard destination.isFileURL, destination.pathExtension == "mid",
              ExportTemporaryFiles.isManagedTemporaryExportFile(destination.path),
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw Failure.unavailable("destination_not_new_managed_temporary_file")
        }
        let app = try currentApp()
        guard try mainWindow(in: app).map({ CFEqual($0, window) }) == true else {
            throw Failure.unavailable("original_window_not_main")
        }
        guard AXLogicProElements.dialogPresenceReason(runtime: runtime) == .noBlockingWindow else {
            throw Failure.unavailable("preexisting_dialog_or_unreadable_modal_state")
        }
        let originalWindows = try windows(app)
        var ownedPanel: AXUIElement?
        do {
            guard let bar: AXUIElement = AXHelpers.getAttribute(app, "AXMenuBar", runtime: runtime.ax) else {
                throw Failure.unavailable("menu_bar_unavailable")
            }
            let file = try label(AXLocalePolicy.fileMenuBar, role: kAXMenuBarItemRole as String, in: bar)
            try act(file, action: kAXPressAction as String)
            let export = try label(AXLocalePolicy.exportMenuItem, role: kAXMenuItemRole as String, in: file)
            try act(export, action: kAXPressAction as String)
            let leaf = try label(AXLocalePolicy.allMIDITracksAsMIDIFileMenuItem, role: kAXMenuItemRole as String, in: export)
            try act(leaf, action: kAXPickAction as String)
            let panel = try await wait("save_panel") {
                let candidates = try self.windows(app).filter { candidate in
                    !originalWindows.contains(where: { CFEqual($0, candidate) })
                }
                guard candidates.count <= 1 else { throw Failure.unavailable("ambiguous_new_windows") }
                guard let panel = candidates.first else { return nil }
                guard AXHelpers.getIdentifier(panel, runtime: self.runtime.ax) == "save-panel",
                      AXHelpers.getRole(panel, runtime: self.runtime.ax) == kAXWindowRole as String else {
                    throw Failure.unavailable("unexpected_new_window")
                }
                return panel
            }
            ownedPanel = panel
            try assertOwned(panel, app: app)
            guard try descendants(panel).allSatisfy({ try string(kAXRoleAttribute as String, of: $0) != kAXSheetRole as String }) else {
                throw Failure.unavailable("unexpected_sheet")
            }
            try assertKeyboardFocus(panel, app: app)
            guard keyboard.post(5, [.maskCommand, .maskShift]) else { throw Failure.unavailable("go_to_folder_key_refused") }
            let go = try await wait("go_to_folder") { try self.unique(identifier: "GoToWindow", role: kAXSheetRole as String, in: panel, optional: true) }
            try assertOwned(panel, app: app)
            let path = try required(identifier: "PathTextField", role: kAXTextFieldRole as String, in: go)
            let directory = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            try setValue(directory, on: path)
            guard let currentGo = try unique(identifier: "GoToWindow", role: kAXSheetRole as String, in: panel),
                  CFEqual(currentGo, go) else { throw Failure.unavailable("owned_go_to_folder_lost") }
            try assertKeyboardFocus(panel, app: app, sheet: go)
            guard keyboard.post(36, []) else { throw Failure.unavailable("go_to_folder_return_refused") }
            _ = try await wait("directory_navigation") { () throws -> AXUIElement? in
                try self.assertOwned(panel, app: app)
                return try self.unique(identifier: "GoToWindow", role: kAXSheetRole as String, in: panel, optional: true) == nil ? panel : nil
            }
            try assertOwned(panel, app: app)
            guard try directorySelected(directory, in: panel) else { throw Failure.unavailable("destination_directory_not_confirmed") }
            let name = try required(identifier: "saveAsNameTextField", role: kAXTextFieldRole as String, in: panel)
            try setValue(destination.lastPathComponent, on: name)
            // Repeat the scope and folder checks after the final field write.
            try assertOwned(panel, app: app)
            guard try directorySelected(directory, in: panel),
                  !FileManager.default.fileExists(atPath: destination.path) else { throw Failure.unavailable("destination_changed") }
            let save = try required(identifier: "OKButton", role: kAXButtonRole as String, in: panel)
            try assertOwned(panel, app: app)
            try act(save, action: kAXPressAction as String, panel: panel, app: app)
            _ = try await wait("save_panel_closed") {
                let current = try self.windows(app)
                return current.contains(where: { CFEqual($0, panel) }) ? nil : self.window
            }
            _ = try currentApp()
            // Panel disappearance is not artifact evidence. The shared file
            // flow separately opens, validates and binds the resulting SMF.
        } catch {
            // Never dismiss a pre-existing or replacement dialog, a new choice
            // sheet, or a panel after project custody has been lost.
            if let panel = ownedPanel, (try? currentApp()) != nil,
               (try? assertOwned(panel, app: app)) != nil,
               let nodes = try? descendants(panel),
               !nodes.contains(where: { AXHelpers.getRole($0, runtime: runtime.ax) == kAXSheetRole as String }),
               let cancel = try? required(identifier: "CancelButton", role: kAXButtonRole as String, in: panel) {
                _ = AXHelpers.performAction(cancel, kAXPressAction as String, runtime: runtime.ax)
            }
            throw error
        }
    }

    private func currentApp() throws -> AXUIElement {
        guard permittingAction(), let app = AXLogicProElements.appRoot(runtime: runtime),
              try windows(app).filter({ CFEqual($0, window) }).count == 1,
              case .success(.some(let current)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
              document.utf8.elementsEqual(current.utf8), permittingAction() else {
            throw Failure.unavailable("project_custody_lost")
        }
        return app
    }

    private func assertOwned(_ panel: AXUIElement, app: AXUIElement) throws {
        try Task.checkCancellation()
        guard CFEqual(try currentApp(), app),
              try windows(app).filter({ CFEqual($0, panel) }).count == 1,
              try string(kAXIdentifierAttribute as String, of: panel) == "save-panel",
              try mainWindow(in: app).map({ CFEqual($0, window) || CFEqual($0, panel) }) == true else {
            throw Failure.unavailable("owned_save_panel_lost")
        }
    }

    private func assertKeyboardFocus(_ panel: AXUIElement, app: AXUIElement, sheet: AXUIElement? = nil) throws {
        let raw: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(app, kAXFocusedWindowAttribute as String, runtime: runtime.ax)
        guard case .success(.some(let value)) = raw, CFGetTypeID(value) == AXUIElementGetTypeID(),
              CFEqual(value, panel) || sheet.map({ CFEqual(value, $0) }) == true else {
            throw Failure.unavailable("owned_save_panel_not_keyboard_focused")
        }
        try assertOwned(panel, app: app)
    }

    private func windows(_ app: AXUIElement) throws -> [AXUIElement] {
        guard case .success(.elements(let values)) = AXHelpers.getAXUIElementArrayRead(app, kAXWindowsAttribute as String, runtime: runtime.ax) else {
            throw Failure.unavailable("windows_unreadable")
        }
        return values
    }

    private func label(_ labels: AXLocalePolicy.LabelSet, role: String, in root: AXUIElement) throws -> AXUIElement {
        guard case .success(let census) = AXLocalePolicy.censusDescendantResult(of: root, role: role,
                matching: labels, mode: .exactStrict, maxDepth: 8, runtime: runtime.ax),
              census.candidates == 1, let element = census.element else { throw Failure.unavailable("menu_label_unavailable_or_ambiguous") }
        return element
    }

    private func descendants(_ root: AXUIElement, stopAtLists: Bool = false, skipBrowserContents: Bool = true) throws -> [AXUIElement] {
        var nodes: [AXUIElement] = []
        var seen: [CFHashCode: [AXUIElement]] = [:]
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        func visit(_ element: AXUIElement, depth: Int) throws {
            try Task.checkCancellation()
            guard depth < 24, nodes.count < 10_000, ContinuousClock.now < deadline else {
                throw Failure.unavailable("panel_tree_limit:\(nodes.count):\(depth)")
            }
            if !CFEqual(element, root) {
                let role = try string(kAXRoleAttribute as String, of: element)
                if stopAtLists && role == kAXListRole as String { return }
                if skipBrowserContents && role == kAXBrowserRole as String,
                   try string(kAXIdentifierAttribute as String, of: element) == "ColumnView" { return }
            }
            let children: [AXUIElement]
            switch AXHelpers.childrenResult(element, runtime: runtime.ax) {
            case .success(let values): children = values
            case .failure(let error) where error.isDefinitiveAbsence: children = []
            case .failure(let error): throw Failure.unavailable("panel_tree_unreadable:\(error.raw)")
            }
            for child in children {
                let hash = CFHash(child)
                guard !(seen[hash] ?? []).contains(where: { CFEqual($0, child) }) else { throw Failure.unavailable("panel_tree_repeated_object") }
                seen[hash, default: []].append(child)
                nodes.append(child); try visit(child, depth: depth + 1)
            }
        }
        try visit(root, depth: 0)
        return nodes
    }

    private func unique(identifier: String, role: String, in root: AXUIElement, optional: Bool = false) throws -> AXUIElement? {
        let matches = try descendants(root).filter {
            try string(kAXRoleAttribute as String, of: $0) == role && string(kAXIdentifierAttribute as String, of: $0) == identifier
        }
        guard matches.count <= 1, optional || matches.count == 1 else { throw Failure.unavailable("panel_control_unavailable_or_ambiguous:\(identifier)") }
        return matches.first
    }

    private func required(identifier: String, role: String, in root: AXUIElement) throws -> AXUIElement {
        guard let result = try unique(identifier: identifier, role: role, in: root) else { throw Failure.unavailable("panel_control_missing:\(identifier)") }
        return result
    }

    private func directorySelected(_ directory: String, in panel: AXUIElement) throws -> Bool {
        let browser = try required(identifier: "ColumnView", role: kAXBrowserRole as String, in: panel)
        // ColumnView's AXList children can include thousands of unrelated
        // files. Read only the column containers and each list's actual
        // selection; file entries are not Save-panel control candidates.
        let lists = try descendants(browser, stopAtLists: true, skipBrowserContents: false).filter {
            try string(kAXRoleAttribute as String, of: $0) == kAXListRole as String
        }
        var selectedDirectories: [URL] = []
        for list in lists {
            let selected: [AXUIElement]
            switch AXHelpers.getAXUIElementArrayRead(list, kAXSelectedChildrenAttribute as String, runtime: runtime.ax) {
            case .success(.elements(let values)): selected = values
            case .success(.absent): continue
            case .failure(let error) where error.isDefinitiveAbsence: continue
            default: throw Failure.unavailable("directory_selection_unreadable")
            }
            for group in selected {
                for field in try descendants(group) where try string(kAXRoleAttribute as String, of: field) == kAXTextFieldRole as String {
                    let raw: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(field, kAXURLAttribute as String, runtime: runtime.ax)
                    guard case .success(.some(let value)) = raw, CFGetTypeID(value) == CFURLGetTypeID(),
                          let url = value as? URL, url.isFileURL,
                          url.host == nil || url.host == "" || url.host == "localhost" else {
                        throw Failure.unavailable("selected_directory_url_unreadable")
                    }
                    selectedDirectories.append(url)
                }
            }
        }
        // Path spelling is not directory ancestry: Foundation may standardize
        // /private/var to /var while leaving an ancestor spelled /private.
        // Ask the filesystem about the actual selected directories, including
        // AppKit's file-reference URLs. Every selected column must remain an
        // ancestor or the destination itself; a deeper selection refuses.
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        var sawDestination = false
        for selected in selectedDirectories {
            var relationship = FileManager.URLRelationship.other
            do {
                try FileManager.default.getRelationship(&relationship, ofDirectoryAt: selected, toItemAt: destination)
            } catch { return false }
            switch relationship {
            case .same: sawDestination = true
            case .contains: break
            case .other: return false
            @unknown default: return false
            }
        }
        return sawDestination
    }

    private func string(_ attribute: String, of element: AXUIElement) throws -> String? {
        let raw: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(element, attribute, runtime: runtime.ax)
        switch raw {
        case .success(.none): return nil
        case .failure(let error) where error.isDefinitiveAbsence: return nil
        case .success(.some(let value)):
            guard CFGetTypeID(value) == CFStringGetTypeID(), let result = value as? String else {
                throw Failure.unavailable("malformed_panel_attribute:\(attribute)")
            }
            return result
        case .failure: throw Failure.unavailable("panel_attribute_unreadable:\(attribute)")
        }
    }

    private func mainWindow(in app: AXUIElement) throws -> AXUIElement? {
        let raw: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(app, kAXMainWindowAttribute as String, runtime: runtime.ax)
        guard case .success(.some(let value)) = raw, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw Failure.unavailable("main_window_unreadable")
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func setValue(_ value: String, on element: AXUIElement) throws {
        try Task.checkCancellation(); _ = try currentApp()
        guard AXHelpers.setAttribute(element, kAXValueAttribute as String, value as CFString, runtime: runtime.ax),
              let actual = try string(kAXValueAttribute as String, of: element),
              value.utf8.elementsEqual(actual.utf8) else { throw Failure.unavailable("field_value_not_confirmed") }
    }

    private func act(_ element: AXUIElement, action: String, panel: AXUIElement? = nil, app: AXUIElement? = nil) throws {
        try Task.checkCancellation(); _ = try currentApp()
        let raw: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(element, kAXEnabledAttribute as String, runtime: runtime.ax)
        guard case .success(.some(let value)) = raw, CFGetTypeID(value) == CFBooleanGetTypeID(),
              (value as? Bool) == true else { throw Failure.unavailable("control_disabled_or_unreadable") }
        if let panel, let app { try assertOwned(panel, app: app) }
        else { _ = try currentApp() }
        _ = AXHelpers.performAction(element, action, runtime: runtime.ax)
    }

    private func wait(_ stage: String, _ read: @MainActor () throws -> AXUIElement?) async throws -> AXUIElement {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        for attempt in 0..<100 {
            try Task.checkCancellation(); _ = try currentApp()
            if let found = try read() { return found }
            guard ContinuousClock.now < deadline else { throw Failure.unavailable("panel_transition_not_observed:\(stage)") }
            if attempt < 99 { try await sleep(100_000_000) }
        }
        throw Failure.unavailable("panel_transition_not_observed:\(stage)")
    }
}
