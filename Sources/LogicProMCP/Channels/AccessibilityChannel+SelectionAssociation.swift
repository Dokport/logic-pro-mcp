@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    /// Explicit held-rail selections, not a name/ordinal join or a global census.
    /// Only a visible Mixer-strip starting focus and one exclusive selection qualify.
    final class HeldSelectionAssociation: @unchecked Sendable {
        struct Pair: @unchecked Sendable {
            let track: AXTrackBinding.Binding
            let strip: AXMixerStripBinding.Binding
            var source = "held_exclusive_selection_focus"
        }
        typealias ViewportControl = (element: AXUIElement, value: Double, zoomDescription: String?)
        let logic: AXLogicProElements.Runtime
        let app: AXUIElement
        let pid: pid_t
        let window: AXUIElement
        let document: String
        let title: String
        let rail: AXUIElement
        let railPath: [AXUIElement]
        let headers: [AXUIElement]
        let mixer: AXUIElement
        let strips: [AXUIElement]
        let path: [AXUIElement]
        let originalIndex: Int
        let originalFocus: AXUIElement
        let transport: AXLogicProElements.ObservedTransportActivity
        let transportPaths: [[AXUIElement]]
        let viewport: [ViewportControl]
        let viewportPaths: [[AXUIElement]]
        private var expectedViewport: [ViewportControl]
        private var expectedIndex: Int
        private var expectedFocus: AXUIElement
        private var originalSelectedChild: AXUIElement?
        private var expectedSelectedChild: AXUIElement?
        private let originalRailFocus: AXUIElement?
        private var lost = false
        private(set) var effects = SessionPopulationObservation.UIEffects()

        init?(window: AXUIElement, logic: AXLogicProElements.Runtime,
              expectedProject: TargetDescriptor?, requiresProjectReference: Bool,
              allowsSelectedChildRailEntry: Bool = false) {
            // The existing foreground AX probe requires this CLI process's
            // window-server connection; a missing/foreign PID still refuses.
            _ = logic.onScreenWindowList()
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let pid = logic.logicProPID(), let app = AXLogicProElements.appRoot(runtime: logic),
                  let title = AXHelpers.getTitle(window, runtime: logic.ax),
                  case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  let url = URL(string: document), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost",
                  !requiresProjectReference || (
                    expectedProject?.projectName?.utf8.elementsEqual(AccessibilityChannel.projectName(fromWindowTitle: title).utf8) == true
                    && expectedProject?.projectFilePath?.utf8.elementsEqual(url.path.utf8) == true),
                  let rail = AXLogicProElements.uniqueTrackHeaderRail(in: window, runtime: logic),
                  let railPath = Self.path(rail, to: window, ax: logic.ax),
                  case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: logic),
                  headers.count > 1,
                  let selected = Self.exclusiveIndex(headers, ax: logic.ax),
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  let mixer = Self.entryMixer(focus: focus, window: window, railPath: railPath,
                    logic: logic, allowsSelectedChildRailEntry: allowsSelectedChildRailEntry),
                  let enumeration = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: logic.ax),
                  enumeration.strips.filter({ CFEqual($0, focus) }).count == 1
                    || (allowsSelectedChildRailEntry && railPath.contains { CFEqual($0, focus) }),
                  let path = Self.path(mixer, to: window, ax: logic.ax),
                  let viewport = Self.viewport(window, ax: logic.ax),
                  let viewportPaths = Self.viewportPaths(viewport, window: window, ax: logic.ax),
                  let activity = try? AXLogicProElements.observedTransportActivity(in: window, runtime: logic,
                    checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                  !activity.isPlaying, !activity.isRecording,
                  let playPath = Self.path(activity.play, to: window, ax: logic.ax),
                  let recordPath = Self.path(activity.record, to: window, ax: logic.ax),
                  playPath.contains(where: { CFEqual($0, activity.controlBar) }),
                  recordPath.contains(where: { CFEqual($0, activity.controlBar) }) else { return nil }
            self.logic = logic; self.app = app; self.pid = pid; self.window = window
            self.title = title; self.document = document; self.rail = rail; self.railPath = railPath; self.headers = headers
            self.mixer = mixer; strips = enumeration.strips; self.path = path
            originalIndex = selected; originalFocus = focus; expectedIndex = selected; expectedFocus = focus
            originalRailFocus = enumeration.strips.contains { CFEqual($0, focus) } ? nil : focus
            transport = activity; self.viewport = viewport
            self.viewportPaths = viewportPaths; expectedViewport = viewport
            transportPaths = [playPath, recordPath]
            if originalRailFocus != nil {
                // A passive rail focus is never a fallback focus/strip pair.
                // This entry needs this exact Mixer's actual held relationship.
                guard case .observed(let child) = selectedChildRead() else { return nil }
                originalSelectedChild = child; expectedSelectedChild = child
            }
            guard permitsRead(), AXHelpers.isAttributeSettable(rail, kAXSelectedChildrenAttribute as String,
                runtime: logic.ax) == true else { return nil }
        }

        private static func entryMixer(focus: AXUIElement, window: AXUIElement,
                                       railPath: [AXUIElement], logic: AXLogicProElements.Runtime,
                                       allowsSelectedChildRailEntry: Bool) -> AXUIElement? {
            guard allowsSelectedChildRailEntry, railPath.contains(where: { CFEqual($0, focus) }) else {
                // Preserve scalar/default acquisition exactly: the focus's
                // original physical parent supplies its Mixer candidate.
                return AXHelpers.getAttribute(focus, kAXParentAttribute as String, runtime: logic.ax)
            }
            guard case .found(let mixer) = (try? AXLogicProElements.mixerPopulationAreaLookup(
                in: window, runtime: logic, requiresCompleteAbsence: true,
                checking: { try SessionPopulationObservation.requireOwnedAcquisition() }))?.lookup else { return nil }
            return mixer
        }

        private static func exclusiveIndex(_ headers: [AXUIElement], ax: AXHelpers.Runtime) -> Int? {
            let values = headers.map { AXValueExtractors.extractSelectedState($0, runtime: ax) }
            guard values.allSatisfy({ $0 != nil }), values.filter({ $0 == true }).count == 1 else { return nil }
            return values.firstIndex(where: { $0 == true })
        }

        private static func same(_ lhs: [AXUIElement], _ rhs: [AXUIElement]) -> Bool {
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { CFEqual($0, $1) }
        }

        private static func path(_ mixer: AXUIElement, to window: AXUIElement, ax: AXHelpers.Runtime) -> [AXUIElement]? {
            var path = [mixer]
            // Preserve the status-bearing childrenResult seam of older runtimes.
            guard ax.attributeValuesResult != nil else {
                while !CFEqual(path.last!, window) {
                    guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                          path.count < 32,
                          let parent: AXUIElement = AXHelpers.getAttribute(path.last!, kAXParentAttribute as String, runtime: ax),
                          !path.contains(where: { CFEqual($0, parent) }),
                          case .success(let children) = AXHelpers.childrenResult(parent, runtime: ax),
                          children.filter({ CFEqual($0, path.last!) }).count == 1 else { return nil }
                    path.append(parent)
                }
                return path
            }
            if CFEqual(mixer, window) { return path }
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let firstParent: AXUIElement = AXHelpers.getAttribute(mixer, kAXParentAttribute as String, runtime: ax) else { return nil }
            var parent = firstParent
            while !CFEqual(path.last!, window) {
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                      path.count < 32,
                      !path.contains(where: { CFEqual($0, parent) }) else { return nil }
                let atWindow = CFEqual(parent, window)
                // Fresh reciprocal witnesses on this original parent, not a
                // cached path or a second hierarchy/name/ordinal lookup. Help
                // remains outside the batch and under its full per-read guard.
                let attributes = atWindow ? [kAXChildrenAttribute as String]
                    : [kAXChildrenAttribute as String, kAXParentAttribute as String]
                let readings = AXHelpers.getNonHelpAttributes(parent, attributes, runtime: ax,
                    permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
                guard case .success(.some(let rawChildren)) = readings[0],
                      CFGetTypeID(rawChildren) == CFArrayGetTypeID(),
                      AXHelpers.decodeChildrenArray(rawChildren).filter({ CFEqual($0, path.last!) }).count == 1 else { return nil }
                path.append(parent)
                if !atWindow {
                    guard case .success(.some(let rawParent)) = readings[1],
                          CFGetTypeID(rawParent) == AXUIElementGetTypeID() else { return nil }
                    parent = unsafeBitCast(rawParent, to: AXUIElement.self)
                }
            }
            return path
        }

        private static func viewport(_ window: AXUIElement, ax: AXHelpers.Runtime,
                                     held: [ViewportControl]? = nil) -> [ViewportControl]? {
            var sliders: [AXUIElement] = []
            guard case .success(let census) = AXHelpers.censusDescendantResult(of: window, role: kAXScrollBarRole as String,
                maxDepth: 32, runtime: ax, requiresCompleteTraversal: true, batchingRoleAndChildren: true,
                permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil },
                observingRole: { element, role in
                    if role == kAXSliderRole as String { sliders.append(element) }
                }) else { return nil }
            var controls: [(AXUIElement, String?)] = census.matches.map { ($0, nil) }
            let zoomLabels = AXLocalePolicy.horizontalZoomSlider.labels + AXLocalePolicy.verticalZoomSlider.labels
            // Discover own zoom controls before navigation. Inspector selection
            // may redraw unrelated sliders; their descriptions cannot revoke
            // custody of an original, reciprocally held viewport control.
            let zooms = held.map { $0.filter { $0.zoomDescription != nil }.map { ($0.element, $0.zoomDescription) } }
                ?? sliders.map { ($0, nil as String?) }
            for (slider, heldDescription) in zooms {
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return nil }
                if heldDescription != nil {
                    // A role contradiction sampled by this fresh census is
                    // irreversible; a later role read cannot erase it.
                    guard sliders.filter({ CFEqual($0, slider) }).count == 1,
                          AXHelpers.getRole(slider, runtime: ax) == kAXSliderRole as String else { return nil }
                }
                switch AXHelpers.getAttributeResult(slider, kAXDescriptionAttribute as String,
                    runtime: ax) as Result<AnyObject?, AXHelpers.AXStatusError> {
                case .success(.some(let rawDescription)):
                    guard CFGetTypeID(rawDescription) == CFStringGetTypeID(),
                          let description = rawDescription as? String else { return nil }
                    if let heldDescription {
                        guard description.utf8.elementsEqual(heldDescription.utf8) else { return nil }
                        controls.append((slider, heldDescription))
                    } else if zoomLabels.contains(description) { controls.append((slider, description)) }
                case .success(.none): if heldDescription != nil { return nil }
                case .failure(let error) where error.isDefinitiveAbsence: if heldDescription != nil { return nil }
                default: return nil
                }
            }
            var result: [ViewportControl] = []
            for (control, description) in controls {
                guard case .success(.some(let value)) = AXHelpers.getAttributeResult(control, kAXValueAttribute as String,
                    runtime: ax) as Result<NSNumber?, AXHelpers.AXStatusError>, value.doubleValue.isFinite else { return nil }
                result.append((control, value.doubleValue, description))
            }
            return result
        }

        private static func viewportPaths(_ viewport: [ViewportControl], window: AXUIElement,
                                          ax: AXHelpers.Runtime) -> [[AXUIElement]]? {
            var paths: [[AXUIElement]] = []
            for (control, _, _) in viewport {
                guard let path = Self.path(control, to: window, ax: ax) else { return nil }
                paths.append(path)
            }
            return paths
        }

        private static func sameViewport(_ lhs: [ViewportControl], _ rhs: [ViewportControl],
                                         includingValues: Bool = true) -> Bool {
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
                CFEqual($0.0, $1.0) && $0.2 == $1.2 && (!includingValues || $0.1 == $1.1)
            }
        }

        private func currentViewport() -> [ViewportControl]? {
            guard let current = Self.viewport(window, ax: logic.ax, held: viewport),
                  Self.sameViewport(current, viewport, includingValues: false),
                  let paths = Self.viewportPaths(current, window: window, ax: logic.ax),
                  paths.count == viewportPaths.count,
                  zip(paths, viewportPaths).allSatisfy({ Self.same($0, $1) }) else {
                lost = true; return nil
            }
            return current
        }

        private func currentWindowScopeMatches() -> Bool {
            guard logic.ax.attributeValuesResult != nil else {
                guard AXHelpers.getTitle(window, runtime: logic.ax)?.utf8.elementsEqual(title.utf8) == true,
                      case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic)
                else { return false }
                return document.utf8.elementsEqual(currentDocument.utf8)
            }
            // Fresh values from this exact held window, not an earlier scope
            // receipt. The separate final Document/PID/deadline bookend remains.
            let values = AXHelpers.getNonHelpAttributes(window,
                [kAXTitleAttribute, kAXDocumentAttribute] as [String], runtime: logic.ax,
                permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            guard case .success(.some(let rawTitle)) = values[0], CFGetTypeID(rawTitle) == CFStringGetTypeID(),
                  let currentTitle = rawTitle as? String, currentTitle.utf8.elementsEqual(title.utf8),
                  case .success(.some(let rawDocument)) = values[1], CFGetTypeID(rawDocument) == CFStringGetTypeID(),
                  let currentDocument = rawDocument as? String else { return false }
            return document.utf8.elementsEqual(currentDocument.utf8)
        }

        private func owned(checkingAssociation: Bool = true, ownedPopup: AXUIElement? = nil) -> Bool {
            func railMatches() -> Bool {
                guard checkingAssociation else { return true }
                guard let currentRailPath = Self.path(rail, to: window, ax: logic.ax), Self.same(railPath, currentRailPath),
                      case .success(let currentHeaders) = AXHelpers.childrenResult(rail, runtime: logic.ax) else { return false }
                return Self.same(headers, currentHeaders)
            }
            func stripCustodyMatches() -> Bool {
                if checkingAssociation || originalRailFocus != nil {
                    guard let current = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: logic.ax) else { return false }
                    return Self.same(strips, current.strips)
                }
                // A focus-moving read is not a rail-selection capability.
                // Renew this exact focus's reciprocal Mixer membership only;
                // never adopt another strip by name or position.
                guard case .success(let children) = AXHelpers.childrenResult(mixer, runtime: logic.ax),
                      children.filter({ CFEqual($0, expectedFocus) }).count == 1,
                      let parent: AXUIElement = AXHelpers.getAttribute(expectedFocus, kAXParentAttribute as String, runtime: logic.ax) else { return false }
                return CFEqual(parent, mixer)
            }
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  logic.logicProPID() == pid, logic.focusedApplicationPID() == pid,
                  let currentApp = AXLogicProElements.appRoot(runtime: logic), CFEqual(app, currentApp) else {
                lost = true; return false
            }
            let application = AXHelpers.getNonHelpAttributes(app,
                [kAXFrontmostAttribute, kAXWindowsAttribute, kAXMainWindowAttribute, kAXFocusedWindowAttribute] as [String],
                runtime: logic.ax, permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            guard case .success(.some(let frontmost)) = application[0], frontmost as? Bool == true,
                  case .success(.some(let windowValues)) = application[1], CFGetTypeID(windowValues) == CFArrayGetTypeID(),
                  case .success(.some(let mainValue)) = application[2], CFGetTypeID(mainValue) == AXUIElementGetTypeID() else {
                let states = application.map { reading -> String in
                    switch reading {
                    case .success(.some(let value)): return "type:\(CFGetTypeID(value))"
                    case .success(.none): return "absent"
                    case .failure(let error): return "AX:\(error.raw)"
                    }
                }.joined(separator: ",")
                Log.info("Held association ownership refused: application window attributes [\(states)]", subsystem: "ax")
                lost = true; return false
            }
            let windows = AXHelpers.decodeChildrenArray(windowValues)
            let main = unsafeBitCast(mainValue, to: AXUIElement.self)
            let focusedWindowMatches = AccessibilityChannel.routingFocusedWindowMatches(application[3],
                window: window, ownedPopup: ownedPopup, mixer: mixer, runtime: logic.ax)
            guard
                  windows.filter({ CFEqual($0, window) }).count == 1,
                  CFEqual(main, window), focusedWindowMatches,
                  currentWindowScopeMatches(), !AXLogicProElements.dialogPresent(runtime: logic) else {
                Log.info("Held association ownership refused: window/dialog (main=\(CFEqual(main, window)), focused=\(focusedWindowMatches))", subsystem: "ax")
                lost = true; return false
            }
            guard railMatches(),
                  let currentPath = Self.path(mixer, to: window, ax: logic.ax), Self.same(path, currentPath),
                  stripCustodyMatches() else {
                Log.info("Held association ownership refused: original rail/Mixer census", subsystem: "ax")
                lost = true; return false
            }
            guard transportPaths.allSatisfy({ held in
                      guard let control = held.first, let current = Self.path(control, to: window, ax: logic.ax),
                            Self.same(held, current) else { return false }
                      let attributes = AXHelpers.getNonHelpAttributes(control, [kAXRoleAttribute, kAXValueAttribute] as [String],
                          runtime: logic.ax, permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
                      guard case .success(.some(let role)) = attributes[0], role as? String == kAXCheckBoxRole as String,
                            case .success(.some(let rawValue)) = attributes[1], let value = rawValue as? NSNumber else { return false }
                      return value == 0
                  }) else {
                Log.info("Held association ownership refused: original transport path/value", subsystem: "ax")
                lost = true; return false
            }
            guard case .success(.some(let finalDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  document.utf8.elementsEqual(finalDocument.utf8), logic.logicProPID() == pid,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { lost = true; return false }
            return true
        }

        /// Only this explicit association observation uses this request-local focus scope.
        /// It does not itself read Help, and cannot admit an editor, key event or
        /// unheld strip. Requested-strip Help remains under its existing guard.
        func permitsRead() -> Bool {
            // Capability reads do not move focus. Validate complete ownership once,
            // after their bookend, rather than repeating the same population census
            // twice for every caller's guarded AX read. Selection writes also
            // require the final scoped action boundary in select().
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                  passiveFocusMatches() else { lost = true; return false }
            guard owned(), Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                  let final: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(final, expectedFocus), selectedChildCustodyMatches() else { lost = true; return false }
            return true
        }

        func permitsOwnedPopupRead(_ root: AXUIElement) -> Bool {
            func heldRailChildMatches() -> Bool {
                guard originalRailFocus != nil else { return true }
                guard let expectedSelectedChild, case .observed(let child) = selectedChildRead(),
                      CFEqual(child, expectedSelectedChild),
                      Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex else { lost = true; return false }
                return true
            }
            // This is not a general editor exemption or a new association. Keep
            // the original complete census and exclusive selection; only allow
            // focus on the search field reciprocally owned by this exact popup.
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                  let menus = AccessibilityChannel.checkedOutputPopupMenus(in: mixer, runtime: logic.ax),
                  menus.count == 1, CFEqual(menus[0], root),
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax)
            else {
                Log.info("Input popup ownership refused: original selection/root/focus", subsystem: "ax")
                lost = true; return false
            }
            guard passiveAssociationFocusMatches(expectedFocus), heldRailChildMatches() else {
                Log.info("Input popup ownership refused: original passive association metadata", subsystem: "ax")
                return false
            }
            // Some owned popups keep the original passive strip focused. Its
            // existing full witness also handles native zero insertion metadata;
            // do not classify that qualified strip as an arbitrary editor.
            if CFEqual(focus, expectedFocus) {
                guard passiveFocusMatches(), owned(ownedPopup: root),
                      Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                      let final: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                      CFEqual(final, expectedFocus), heldRailChildMatches(), passiveAssociationFocusMatches(expectedFocus),
                      let afterChild: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                      CFEqual(afterChild, expectedFocus) else { lost = true; return false }
                return true
            }
            guard
                  AXHelpers.getRole(focus, runtime: logic.ax) == kAXTextFieldRole as String,
                  case .success(let rows) = AXHelpers.childrenResult(root, runtime: logic.ax),
                  let parent: AXUIElement = AXHelpers.getAttribute(focus, kAXParentAttribute as String, runtime: logic.ax)
            else { lost = true; return false }
            if CFEqual(parent, root) {
                guard rows.filter({ CFEqual($0, focus) }).count == 1 else { lost = true; return false }
            } else {
                guard rows.filter({ CFEqual($0, parent) }).count == 1,
                      let role = AXHelpers.getRole(parent, runtime: logic.ax),
                      role == kAXGroupRole as String || role == "AXMenuItem",
                      let parentRoot: AXUIElement = AXHelpers.getAttribute(parent, kAXParentAttribute as String, runtime: logic.ax),
                      CFEqual(parentRoot, root),
                      case .success(let children) = AXHelpers.childrenResult(parent, runtime: logic.ax),
                      children.filter({ CFEqual($0, focus) }).count == 1 else { lost = true; return false }
            }
            guard let current = AccessibilityChannel.checkedOutputPopupMenus(in: mixer, runtime: logic.ax),
                  current.count == 1, CFEqual(current[0], root),
                  let final: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(final, focus) else {
                Log.info("Input popup ownership refused: reciprocal focus/root", subsystem: "ax")
                lost = true; return false
            }
            guard owned(ownedPopup: root) else {
                Log.info("Input popup ownership refused: full association custody", subsystem: "ax")
                return false
            }
            guard
                  Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                  heldRailChildMatches(), passiveAssociationFocusMatches(expectedFocus),
                  currentWindowScopeMatches(), logic.logicProPID() == pid,
                  logic.focusedApplicationPID() == pid,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let afterChild: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(afterChild, focus) else { lost = true; return false }
            return true
        }

        /// Only ReadFocusScope uses this witness. Full exclusive-selection and
        /// population custody still authorize every association action, inverse
        /// and publication. Passive Help never acquires that authority.
        func permitsPassiveFocusRead() -> Bool {
            guard passiveFocusMatches(), owned(checkingAssociation: false),
                  let final: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(final, expectedFocus),
                  let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: logic.ax),
                  CFEqual(main, window),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: logic.ax),
                  CFEqual(focusedWindow, window),
                  case .success(.some(let finalDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  document.utf8.elementsEqual(finalDocument.utf8), logic.logicProPID() == pid,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { lost = true; return false }
            return true
        }

        private func passiveFocusMatches() -> Bool {
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(focus, expectedFocus) else { lost = true; return false }
            return passiveAssociationFocusMatches(focus)
        }

        private func passiveAssociationFocusMatches(_ focus: AXUIElement) -> Bool {
            if strips.contains(where: { CFEqual($0, focus) }) { return passiveStripMatches(focus) }
            guard let originalRailFocus, CFEqual(focus, originalRailFocus), expectedSelectedChild != nil,
                  let role = AXHelpers.getRole(focus, runtime: logic.ax),
                  [kAXGroupRole as String, kAXListRole as String, kAXLayoutAreaRole as String].contains(role),
                  AXHelpers.isAttributeSettable(focus, kAXValueAttribute as String, runtime: logic.ax) == false,
                  let currentPath = Self.path(rail, to: window, ax: logic.ax), Self.same(railPath, currentPath),
                  currentPath.contains(where: { CFEqual($0, focus) }) else { lost = true; return false }
            let attributes = [kAXValueAttribute, kAXSelectedTextAttribute,
                              kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute] as [String]
            let readings = AXHelpers.getNonHelpAttributes(focus, attributes, runtime: logic.ax,
                permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            // Unlike the already-qualified passive strip, a rail container gets
            // no zero-insertion/editor exception and no settable focus cleanup.
            guard readings.allSatisfy({ reading in
                if case .failure(let error) = reading { return error.isDefinitiveAbsence }
                return false
            }) else { lost = true; return false }
            return true
        }

        private func passiveStripMatches(_ focus: AXUIElement) -> Bool {
            guard strips.filter({ CFEqual($0, focus) }).count == 1,
                  AXHelpers.getRole(focus, runtime: logic.ax) == kAXLayoutItemRole as String,
                  AXHelpers.isAttributeSettable(focus, kAXValueAttribute as String, runtime: logic.ax) == false else { lost = true; return false }
            let attributes = [kAXValueAttribute, kAXSelectedTextAttribute,
                              kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute] as [String]
            let readings = AXHelpers.getNonHelpAttributes(focus, attributes, runtime: logic.ax,
                permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            for (attribute, reading) in zip(attributes, readings) {
                switch reading {
                case .failure(let error) where error.isDefinitiveAbsence: continue
                case .success(.some(let value)):
                    guard attribute == kAXNumberOfCharactersAttribute as String || attribute == kAXInsertionPointLineNumberAttribute as String,
                          CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber,
                          number.doubleValue == 0 else { lost = true; return false }
                default: lost = true; return false
                }
            }
            return true
        }

        private enum SelectedChildRead {
            case unavailable, unverified
            case observed(AXUIElement)
        }

        /// A relationship supplied by this exact Mixer owner, not a strip ordinal
        /// or name join. Individual strip AXSelected booleans are not equivalent.
        private func selectedChildRead() -> SelectedChildRead {
            let values = AXHelpers.getNonHelpAttributes(mixer, [kAXSelectedChildrenAttribute as String],
                runtime: logic.ax, permittingRead: {
                    (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
                })
            switch values[0] {
            case .failure(let error) where error.isDefinitiveAbsence: return .unavailable
            case .success(.none): return .unavailable
            case .success(.some(let raw)):
                guard CFGetTypeID(raw) == CFArrayGetTypeID() else { return .unverified }
                let array = unsafeDowncast(raw, to: CFArray.self)
                guard CFArrayGetCount(array) == 1 else { return .unverified }
                let element = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFTypeRef.self)
                guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return .unverified }
                let child = unsafeBitCast(element, to: AXUIElement.self)
                // Renew reciprocal membership after the relationship read: a
                // retired child can retain its old parent and CF identity.
                guard let current = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: logic.ax),
                      Self.same(strips, current.strips),
                      current.strips.filter({ CFEqual($0, child) }).count == 1,
                      let parent: AXUIElement = AXHelpers.getAttribute(child, kAXParentAttribute as String,
                        runtime: logic.ax), CFEqual(parent, mixer) else { return .unverified }
                return .observed(child)
            default: return .unverified
            }
        }

        private var associationStrip: AXUIElement { expectedSelectedChild ?? expectedFocus }

        private func railMetadataRetainsStripCustody() -> Bool {
            guard originalRailFocus != nil else { return true }
            // R965-RAIL-C001: the new rail metadata reads can retire an old
            // selected child while leaving its old parent/relationship readable.
            guard let current = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: logic.ax) else { return false }
            return Self.same(strips, current.strips)
        }

        private func selectedChildCustodyMatches() -> Bool {
            guard let expectedSelectedChild else { return true }
            guard case .observed(let child) = selectedChildRead(), CFEqual(child, expectedSelectedChild),
                  Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String,
                    runtime: logic.ax), CFEqual(focus, expectedFocus), passiveAssociationFocusMatches(focus),
                  railMetadataRetainsStripCustody(),
                  let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: logic.ax),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: logic.ax),
                  CFEqual(main, window), CFEqual(focusedWindow, window), currentWindowScopeMatches(),
                  logic.logicProPID() == pid, logic.focusedApplicationPID() == pid,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                lost = true; return false
            }
            return true
        }

        private func select(_ index: Int, referenceIsCurrent: @Sendable () async -> Bool,
                            stoppingWhen stop: @Sendable () -> Bool) async -> Bool {
            guard !lost, !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  AXHelpers.isAttributeSettable(rail, kAXSelectedChildrenAttribute as String,
                runtime: logic.ax) == true,
                  let beforeViewport = currentViewport(), Self.sameViewport(beforeViewport, expectedViewport),
                  permitsRead(), !stop(),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  owned(), selectedChildCustodyMatches() else { return false }
            // The selected-child read is a new deciding read. Renew the request
            // reference after it, then check the pure lease without another AX
            // read before the selection write.
            if expectedSelectedChild != nil {
                guard await referenceIsCurrent(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            }
            // R965-ASSOC-C001: the deciding focus/selection reads in permitsRead
            // can themselves coincide with a document/window switch. Revalidate
            // scoped ownership AFTER them, with no further AX read before write.
            effects.navigationPerformed = true; effects.restoration = "not_restored"
            if !effects.attempted.contains("track_selection") { effects.attempted.append("track_selection") }
            let precedingFocus = expectedFocus
            let precedingSelectedChild = expectedSelectedChild
            let accepted = AXHelpers.setAttribute(rail, kAXSelectedChildrenAttribute as String, [headers[index]] as CFArray, runtime: logic.ax)
            for attempt in 0..<4 {
                guard owned() else { return false }
                let selectionChanged = Self.exclusiveIndex(headers, ax: logic.ax) == index
                if selectionChanged, !effects.changed.contains("track_selection") {
                    effects.changed.append("track_selection")
                }
                guard let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                      strips.filter({ CFEqual($0, focus) }).count == 1
                        || originalRailFocus.map({ CFEqual($0, focus) }) == true else {
                    lost = true; return false
                }
                if selectionChanged {
                    let selectedChild: AXUIElement?
                    if precedingSelectedChild != nil {
                        guard case .observed(let child) = selectedChildRead() else { lost = true; return false }
                        selectedChild = child
                    } else { selectedChild = nil }
                    // Selection and its Mixer relationship can settle on
                    // different host turns. Do not freeze the old strip as a pair.
                    // Only original held strips are admitted by the guard above.
                    let awaitingOwnFocus: Bool
                    if let selectedChild, let precedingSelectedChild, let originalSelectedChild {
                        awaitingOwnFocus = index == originalIndex
                            ? !CFEqual(selectedChild, originalSelectedChild) : CFEqual(selectedChild, precedingSelectedChild)
                    } else {
                        awaitingOwnFocus = index == originalIndex
                            ? !CFEqual(focus, originalFocus) : CFEqual(focus, precedingFocus)
                    }
                    if awaitingOwnFocus && attempt < 3 {
                        do { try await Task.sleep(for: .milliseconds(30)) } catch { return false }
                        continue
                    }
                    guard let afterViewport = currentViewport() else { return false }
                    // Logic can select our exact held header while retaining its
                    // original Mixer relationship. Retain that owned transition
                    // for inverse cleanup; observe() still requires a different
                    // challenge strip before publishing any association pair.
                    expectedIndex = index; expectedFocus = focus
                    expectedSelectedChild = selectedChild
                    expectedViewport = afterViewport
                    return permitsRead() && !stop() && accepted
                }
                if attempt < 3 {
                    do { try await Task.sleep(for: .milliseconds(30)) } catch { return false }
                }
            }
            return false
        }

        /// Reverse only scroll/own-zoom values sampled immediately after our held-rail selections.
        /// A newer viewport, replacement control/path or scope loss ends cleanup authority.
        private func restoreViewport(referenceIsCurrent: @Sendable () async -> Bool,
                                     stoppingWhen stop: @Sendable () -> Bool) async -> Bool {
            guard let current = currentViewport(), Self.sameViewport(current, expectedViewport) else { return false }
            for index in viewport.indices where viewport[index].1 != expectedViewport[index].1 {
                let (control, original, _) = viewport[index]
                guard !stop(), await referenceIsCurrent(), permitsRead(),
                      (0...1).contains(original),
                      AXHelpers.isAttributeSettable(control, kAXValueAttribute as String, runtime: logic.ax) == true,
                      let decidingViewport = currentViewport(), Self.sameViewport(decidingViewport, expectedViewport),
                      permitsRead(), owned(), await referenceIsCurrent(), !stop(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
                // R965-VIEW-C001: the deciding AX reads can retire the request's
                // reference without changing physical custody. Renew it last,
                // then require pure acquisition/cancellation authority before writing.
                if !effects.attempted.contains("viewport") { effects.attempted.append("viewport") }
                let accepted = AXHelpers.setAttribute(control, kAXValueAttribute as String,
                    NSNumber(value: original), runtime: logic.ax)
                guard let after = currentViewport() else { return false }
                if after[index].1 == original, !effects.changed.contains("viewport") { effects.changed.append("viewport") }
                guard accepted, after[index].1 == original,
                      zip(after.indices, after).allSatisfy({ entry in
                          entry.0 == index || entry.1.1 == expectedViewport[entry.0].1
                      }), permitsRead(), owned(), !stop() else { return false }
                expectedViewport = after
            }
            return Self.sameViewport(expectedViewport, viewport)
        }

        /// Cleanup of an original passive focus is not an association challenge.
        /// Logic may restore the held selection while retaining the prior strip's
        /// focus; never publish a pair manufactured by this explicit inverse.
        private func restoreOriginalFocus(referenceIsCurrent: @Sendable () async -> Bool,
                                          stoppingWhen stop: @Sendable () -> Bool) async -> Bool {
            guard expectedIndex == originalIndex, !CFEqual(expectedFocus, originalFocus),
                  !stop(), await referenceIsCurrent(), passiveStripMatches(originalFocus),
                  let originalPath = Self.path(originalFocus, to: window, ax: logic.ax),
                  Self.same(originalPath, [originalFocus] + path),
                  AXHelpers.isAttributeSettable(originalFocus, kAXFocusedAttribute as String, runtime: logic.ax) == true,
                  let beforeViewport = currentViewport(), Self.sameViewport(beforeViewport, expectedViewport),
                  permitsRead(), !stop(), owned(),
                  // The final census may retire a reference or move focus while
                  // leaving document, population and transport intact. Renew the
                  // deciding focus, then scope and reference, after that census.
                  let decidingFocus: AXUIElement = AXHelpers.getAttribute(app,
                    kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(decidingFocus, expectedFocus),
                  Self.exclusiveIndex(headers, ax: logic.ax) == originalIndex,
                  let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: logic.ax),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: logic.ax),
                  CFEqual(main, window), CFEqual(focusedWindow, window), currentWindowScopeMatches(),
                  logic.logicProPID() == pid, logic.focusedApplicationPID() == pid,
                  await referenceIsCurrent(), !stop(),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            if !effects.attempted.contains("keyboard_focus_restoration") {
                effects.attempted.append("keyboard_focus_restoration")
            }
            guard AXHelpers.setAttribute(originalFocus, kAXFocusedAttribute as String,
                NSNumber(value: true), runtime: logic.ax) else { return false }
            let precedingFocus = expectedFocus
            for attempt in 0..<3 {
                // As in select(), renew our observed focus before consulting
                // the passive editing guard: it still holds the preceding focus
                // until then. owned() preserves cancellation, deadline, document,
                // transport and complete population custody during this inverse.
                guard owned(),
                      let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String,
                        runtime: logic.ax) else { return false }
                if CFEqual(focus, originalFocus) {
                    guard let afterViewport = currentViewport() else { return false }
                    expectedFocus = originalFocus; expectedViewport = afterViewport
                    guard permitsRead(), !stop(), await referenceIsCurrent() else { return false }
                    if !effects.changed.contains("keyboard_focus_restoration") {
                        effects.changed.append("keyboard_focus_restoration")
                    }
                    return true
                }
                guard CFEqual(focus, precedingFocus), attempt < 2 else { lost = true; return false }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
            }
            return false
        }

        func observe(referenceIsCurrent: @Sendable () async -> Bool,
                     stoppingWhen stop: @Sendable () -> Bool,
                     allHeldHeaders: Bool = false,
                     populationReadDuration: Duration = .zero,
                     collectionNow: @Sendable () -> ContinuousClock.Instant = { .now }) async -> [Pair] {
            guard allHeldHeaders || originalRailFocus == nil,
                  let firstChallenge = headers.indices.first(where: { $0 != originalIndex }),
                  await referenceIsCurrent(), permitsRead(), !stop() else { return [] }
            if allHeldHeaders {
                switch selectedChildRead() {
                case .observed(let child):
                    originalSelectedChild = child; expectedSelectedChild = child
                    guard permitsRead(), !stop() else { return [] }
                case .unavailable: break
                case .unverified:
                    effects.reason = "association_selection_unverified"; return []
                }
            }
            let originalAssociationStrip = originalSelectedChild ?? originalFocus
            let challenges = allHeldHeaders ? headers.indices.filter { $0 != originalIndex } : [firstChallenge]
            // Whole-held pairs are optional partial observations. Do not spend
            // the entire owned deadline on more challenges: the original inverse
            // and final fresh population still need that same deadline. This is
            // not an extension or a guarantee that a busy host will restore.
            let collectionEnd: ContinuousClock.Instant?
            if allHeldHeaders, let deadline = OperationTraceContext.current?.deadline {
                let start = collectionNow()
                let remaining = start.duration(to: deadline)
                // Use the initial fresh population's observed cost, not just a
                // fraction of the deadline. With insufficient recheck time,
                // preserve the initial snapshot without starting UI navigation.
                let reserve = max(.zero, populationReadDuration) * 2
                guard remaining > reserve else { return [] }
                // An actual measured reserve already bounds the available
                // work. Keep the conservative fraction only without a sample;
                // do not truncate otherwise qualified original-header pairs.
                collectionEnd = start.advanced(by: reserve > .zero ? remaining - reserve : remaining / 4)
            } else { collectionEnd = nil }
            var observed: [(Int, AXUIElement)] = []
            var restored = true
            var selectionsVerified = true
            // An initially selected header and passive focus are not a pair
            // witness. Whole-held collection needs its own changed-strip return
            // to that header, just as it does for every challenged header.
            var originalPairVerified = !allHeldHeaders
            for challenge in challenges {
                if let collectionEnd, collectionNow() >= collectionEnd { break }
                // select() renews selection/focus and the complete scoped
                // ownership after its deciding viewport reads and immediately
                // before the action. Do not repeat that census here.
                guard await referenceIsCurrent(), !stop() else { restored = false; break }
                let precedingStrip = associationStrip
                let advanced = await select(challenge, referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop)
                let challengeFocus = expectedFocus
                let challengeStrip = associationStrip
                if allHeldHeaders {
                    guard advanced else { selectionsVerified = false; break }
                    if !CFEqual(challengeStrip, precedingStrip) {
                        // The exclusive header and a changed Mixer relationship
                        // are renewed together under full held census
                        // custody. Intermediate proofs need no inverse action.
                        observed.append((challenge, challengeStrip))
                    } else if !CFEqual(precedingStrip, originalAssociationStrip) {
                        // An unchanged relationship is not alias evidence. Challenge that
                        // header again from the original strip; if it still does
                        // not change strip, leave just this association unknown.
                        guard await referenceIsCurrent(),
                              await select(originalIndex, referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop) else {
                            selectionsVerified = false; break
                        }
                        if !CFEqual(associationStrip, originalAssociationStrip) {
                            // The original selection can retain a still-owned
                            // preceding strip. That is no fresh baseline or pair
                            // proof, but it does not contradict earlier pairs.
                            originalPairVerified = false
                            continue
                        }
                        originalPairVerified = true
                        guard await referenceIsCurrent(),
                              await select(challenge, referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop) else {
                            selectionsVerified = false; break
                        }
                        if !CFEqual(associationStrip, originalAssociationStrip) { observed.append((challenge, associationStrip)) }
                    }
                    continue
                }
                if expectedIndex == originalIndex {
                    restored = permitsRead() && CFEqual(expectedFocus, originalFocus)
                } else if await referenceIsCurrent() {
                    restored = await select(originalIndex, referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop) && CFEqual(expectedFocus, originalFocus)
                } else { restored = false }
                // Each proof starts at the same original selection/focus. A
                // previous challenge's passive focus cannot identify this header.
                guard restored else { break }
                guard advanced, !CFEqual(challengeFocus, originalFocus) else {
                    selectionsVerified = false; break
                }
                observed.append((challenge, challengeFocus))
            }
            if allHeldHeaders {
                func selectedChildRestored() -> Bool {
                    guard let originalSelectedChild, let expectedSelectedChild else { return true }
                    return CFEqual(originalSelectedChild, expectedSelectedChild)
                }
                if expectedIndex == originalIndex {
                    restored = permitsRead() && CFEqual(expectedFocus, originalFocus) && selectedChildRestored()
                } else if await referenceIsCurrent() {
                    let precedingStrip = associationStrip
                    let returned = await select(originalIndex, referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop)
                    if returned, CFEqual(associationStrip, originalAssociationStrip),
                       !CFEqual(precedingStrip, originalAssociationStrip) { originalPairVerified = true }
                    restored = returned && CFEqual(expectedFocus, originalFocus) && selectedChildRestored()
                } else { restored = false }
                if !restored, !lost, expectedIndex == originalIndex {
                    if originalSelectedChild == nil { originalPairVerified = false }
                    restored = await restoreOriginalFocus(referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop)
                        && selectedChildRestored()
                }
            }
            let inverseVerified: Bool
            if restored { inverseVerified = await restoreViewport(referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop) }
            else { inverseVerified = false }
            let sampledViewport = currentViewport()
            let viewRestored = inverseVerified && (sampledViewport.map { values in
                Self.sameViewport(values, viewport)
            } ?? false)
            guard restored, viewRestored, await referenceIsCurrent(), permitsRead(), !stop() else {
                effects.reason = "association_restoration_unverified"; return []
            }
            effects.restoration = "restored"
            guard selectionsVerified, !observed.isEmpty else {
                effects.reason = "association_selection_unverified"; return []
            }
            return (observed + (originalPairVerified ? [(originalIndex, originalAssociationStrip)] : [])).map { index, strip in
                Pair(track: .init(window: window, header: headers[index], document: document, runtime: logic),
                     strip: .init(window: window, mixer: mixer, strip: strip, document: document),
                     source: originalSelectedChild == nil ? "held_exclusive_selection_focus" : "held_exclusive_selection_selected_child")
            }
        }
    }
}
