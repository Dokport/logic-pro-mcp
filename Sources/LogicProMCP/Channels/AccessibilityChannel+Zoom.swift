@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    /// Explicit track-height control. Never substitute a horizontal zoom key command.
    /// The original header's split-view body and the slider toolbar must be direct
    /// siblings in the same Tracks area. A shared outer group is not Arrange identity.
    static func defaultSetVerticalZoomLevel(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        func refused(_ reason: String) -> ChannelResult {
            .error(HonestContract.encodeStateC(error: .invalidParams, hint: reason,
                extras: ["operation": "nav.set_zoom", "axis": "vertical", "write_attempted": false]))
        }
        guard params["axis"] == nil || params["axis"] == "vertical",
              let text = params["level"], let level = Int(text), (1...10).contains(level) else {
            return refused("Vertical set_zoom requires level 1..10 and axis vertical")
        }
        func owned() -> Bool {
            do { try SessionPopulationObservation.requireOwnedAcquisition(); return true }
            catch { return false }
        }
        func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
            guard owned() else { return nil }
            return AXHelpers.getAttribute(element, name, runtime: runtime.ax)
        }
        func scalar(_ element: AXUIElement, _ name: String) -> Double? {
            guard let value: NSNumber = attribute(element, name),
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        guard owned(), let app = AXLogicProElements.appRoot(runtime: runtime),
              let window: AXUIElement = attribute(app, kAXMainWindowAttribute as String),
              let role: String = attribute(window, kAXRoleAttribute as String), role == (kAXWindowRole as String),
              let document: String = attribute(window, kAXDocumentAttribute as String), !document.isEmpty else {
            return refused("Original project window or mutation ownership unavailable")
        }
        func windowHeld() -> Bool {
            guard owned(), let currentApp = AXLogicProElements.appRoot(runtime: runtime), CFEqual(currentApp, app),
                  let current: AXUIElement = attribute(app, kAXMainWindowAttribute as String),
                  CFEqual(current, window), let currentDocument: String = attribute(window, kAXDocumentAttribute as String)
            else { return false }
            return currentDocument == document
        }
        // Require reciprocal native ancestry all the way to this original window.
        func ancestors(_ element: AXUIElement) -> [AXUIElement]? {
            var child = element, path: [AXUIElement] = []
            for _ in 0..<32 {
                guard let parent: AXUIElement = attribute(child, kAXParentAttribute as String),
                      !path.contains(where: { CFEqual($0, parent) }), owned(),
                      case .success(let children) = AXHelpers.childrenResult(parent, runtime: runtime.ax),
                      children.filter({ CFEqual($0, child) }).count == 1 else { return nil }
                if CFEqual(parent, window) { return path }
                path.append(parent)
                child = parent
            }
            return nil
        }
        func locate() -> AXUIElement? {
            guard windowHeld(),
                  case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
                  let header = headers.first, let headerPath = ancestors(header) else { return nil }
            // Observed native structure: header rail -> scroll area -> split group(s)
            // -> body group -> area group; zoom -> toolbar group -> SAME area.
            // Neither a title match nor an arbitrary common ancestor proves this.
            var splitIndex: Int?
            for (index, ancestor) in headerPath.enumerated() {
                guard let role: String = attribute(ancestor, kAXRoleAttribute as String) else { return nil }
                if role == (kAXSplitGroupRole as String) {
                    splitIndex = index
                } else if splitIndex != nil {
                    break
                }
            }
            guard let splitIndex, splitIndex + 2 < headerPath.count,
                  let bodyRole: String = attribute(headerPath[splitIndex + 1], kAXRoleAttribute as String),
                  bodyRole == (kAXGroupRole as String),
                  let areaRole: String = attribute(headerPath[splitIndex + 2], kAXRoleAttribute as String),
                  areaRole == (kAXGroupRole as String),
                  case .success(let census) = AXHelpers.censusDescendantResult(of: window, role: kAXSliderRole,
                    maxDepth: 24, runtime: runtime.ax, requiresCompleteTraversal: true, permittingRead: owned)
            else { return nil }
            let area = headerPath[splitIndex + 2]
            var metadataReadable = true
            let candidates = census.matches.filter { slider in
                let description: String?
                switch AXHelpers.getAttributeResult(slider, kAXDescriptionAttribute as String, runtime: runtime.ax)
                    as Result<String?, AXHelpers.AXStatusError> {
                case .success(let text): description = text
                case .failure(let error) where error.isDefinitiveAbsence: return false
                case .failure: metadataReadable = false; return false
                }
                guard owned(), let description, AXLocalePolicy.verticalZoomSlider.matches(description) else { return false }
                guard let path = ancestors(slider) else { metadataReadable = false; return false }
                guard path.count >= 2 else { return false }
                guard let toolbarRole: String = attribute(path[0], kAXRoleAttribute as String) else {
                    metadataReadable = false
                    return false
                }
                return toolbarRole == (kAXGroupRole as String) && CFEqual(path[1], area)
            }
            guard metadataReadable, candidates.count == 1, windowHeld() else { return nil }
            return candidates[0]
        }
        guard let slider = locate(), scalar(slider, kAXMinValueAttribute as String) == 0,
              scalar(slider, kAXMaxValueAttribute as String) == 1,
              let before = scalar(slider, kAXValueAttribute as String), (0...1).contains(before), owned(),
              AXHelpers.isAttributeSettable(slider, kAXValueAttribute as String, runtime: runtime.ax) == true else {
            return refused("A unique, writable Arrange Vertical Zoom slider could not be verified")
        }
        let target = Double(level - 1) / 9.0
        guard let deciding = locate(), CFEqual(deciding, slider),
              scalar(slider, kAXValueAttribute as String) == before,
              scalar(slider, kAXMinValueAttribute as String) == 0,
              scalar(slider, kAXMaxValueAttribute as String) == 1, windowHeld(), owned() else {
            return refused("Original vertical zoom control changed before the write")
        }
        // Native level 8 reads 0.7777777314186096: one Float step below
        // Float(7/9), not the exact Double request. Larger discrepancies refuse.
        let precision = Double(Float(target).ulp)
        let alreadyAtTarget = abs(before - target) <= precision
        let acknowledged = alreadyAtTarget || AXValueExtractors.setSliderValue(slider, target, runtime: runtime.ax)
        if !alreadyAtTarget { usleep(120_000) }
        let controlHeld = locate().map { CFEqual($0, slider) } == true && windowHeld()
        let after = controlHeld ? scalar(slider, kAXValueAttribute as String) : nil
        let held = controlHeld && windowHeld()
        let extras: [String: Any] = ["operation": "nav.set_zoom", "axis": "vertical", "level": level,
            "requested": target, "observed_before": before, "observed": after ?? NSNull(),
            "observed_after": after ?? NSNull(), "verify_source": "ax_zoom_slider",
            "write_attempted": !alreadyAtTarget, "write_acknowledged": acknowledged,
            "readback_tolerance": precision]
        if acknowledged, held, let after, (0...1).contains(after), abs(after - target) <= precision {
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        return .success(HonestContract.encodeStateB(
            reason: after == nil || !held ? .readbackUnavailable : .readbackMismatch, extras: extras))
    }
}
