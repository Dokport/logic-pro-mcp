import ApplicationServices
import Foundation

/// The Logic-side primitives of `tracks.prepare_vocal`, each read back by its caller.
///
/// Measured on Logic Pro 12.4 (en-US), 2026-10-27:
/// - every region of the arrangement is an `AXLayoutItem` whose help sentence carries its start
///   and end to the tick, on or off screen;
/// - a click on a track header's free area selects every region of that track for real;
/// - `AXSelected` written on regions makes a selection Delete and Join act on (Join of regions
///   that play one continuous stretch of one file makes one region and no new audio file);
/// - Navigate > Go To > Position… takes "bar beat division tick" typed into its focused field;
/// - Edit > Split > Regions at Playhead splits only the selected region under the playhead;
/// - Edit > Trim > Region End to Next Region / Region Start to Previous Region close gaps with
///   the region's own audio;
/// - a region's own border handles do not trim through AX; a drag on its lower corner does;
/// - the Region inspector's Fade-In / Fade-Out sliders take an `AXValue` write for ONE selected
///   region (with several selected the change is relative), and Type is a pop-up (Out, X, …).
/// The menu titles are the English ones; another UI language refuses with `menu_item_absent`.
extension AccessibilityChannel {
    struct VocalRegionItem {
        let element: AXUIElement
        let name: String
        let start: Double
        let end: Double
        let selected: Bool
        let frame: CGRect?
    }

    /// Every region of track `index` (by the header's vertical extent), sorted by start.
    static func vocalTrackRegions(index: Int, tempo: Double, runtime: AXLogicProElements.Runtime = .production) -> [VocalRegionItem]? {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime),
              let header = AXLogicProElements.findTrackHeader(at: index, runtime: runtime),
              let hp = AXHelpers.getPosition(header, runtime: runtime.ax),
              let hs = AXHelpers.getSize(header, runtime: runtime.ax) else { return nil }
        let items = AXHelpers.findAllDescendants(of: window, role: "AXLayoutItem", maxDepth: 14, runtime: runtime.ax)
        var out: [VocalRegionItem] = []
        for item in items {
            let help = AXHelpers.getHelp(item, runtime: runtime.ax) ?? ""
            guard AXLocalePolicy.regionHelpKeyword.containsAny(in: help),
                  let p = AXHelpers.getPosition(item, runtime: runtime.ax),
                  let s = AXHelpers.getSize(item, runtime: runtime.ax) else { continue }
            let midY = p.y + s.height / 2
            guard midY >= hp.y, midY <= hp.y + hs.height else { continue }
            guard let span = VocalPrep.parseRegionSpan(help: help, tempo: tempo) else { return nil }
            let selected: Bool? = AXHelpers.getAttribute(item, kAXSelectedAttribute as String, runtime: runtime.ax)
            out.append(VocalRegionItem(element: item, name: AXHelpers.getDescription(item, runtime: runtime.ax) ?? "",
                                       start: span.start, end: span.end, selected: selected == true,
                                       frame: CGRect(origin: p, size: s)))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// A click on the header's free area (between the focus marker and the first button): every
    /// region of the track selected, read back. A click on the name field instead starts renaming
    /// a selected track whose name reaches the click (measured with "2 voc kvæd").
    static func vocalSelectTrack(index: Int, tempo: Double, runtime: AXLogicProElements.Runtime = .production) -> Bool {
        guard let header = AXLogicProElements.findTrackHeader(at: index, runtime: runtime),
              let hp = AXHelpers.getPosition(header, runtime: runtime.ax),
              let hs = AXHelpers.getSize(header, runtime: runtime.ax) else { return false }
        let children = AXHelpers.getChildren(header, runtime: runtime.ax)
        func frames(_ role: String) -> [CGRect] {
            children.filter { AXHelpers.getRole($0, runtime: runtime.ax) == role }.compactMap { child in
                guard let p = AXHelpers.getPosition(child, runtime: runtime.ax), let s = AXHelpers.getSize(child, runtime: runtime.ax) else { return nil }
                return CGRect(origin: p, size: s)
            }
        }
        let left = frames(kAXRadioButtonRole as String).map(\.maxX).max() ?? hp.x
        let right = frames(kAXCheckBoxRole as String).map(\.minX).min() ?? hp.x + 90
        guard right - left >= 6 else { return false }
        _ = AXMouseHelper.click(at: CGPoint(x: (left + right) / 2, y: hp.y + min(hs.height, 19) / 2))
        usleep(300_000)
        guard let regions = vocalTrackRegions(index: index, tempo: tempo, runtime: runtime), !regions.isEmpty else { return false }
        return regions.allSatisfy(\.selected)
    }

    /// Measured on 12.4: a menu item's `AXEnabled` (and whether AXPress acts) is only re-validated
    /// when its menu opens, so an item can read disabled long after it became available. Such an
    /// item gets its top-level menu opened first; still disabled then, the menu is closed again.
    static func vocalPressMenu(_ path: [String], runtime: AXLogicProElements.Runtime = .production) -> Bool {
        guard let item = AXLogicProElements.menuItem(path: path, runtime: runtime) else { return false }
        func enabled() -> Bool { (AXHelpers.getAttribute(item, kAXEnabledAttribute as String, runtime: runtime.ax) as Bool?) != false }
        if !enabled() {
            guard let top = AXLogicProElements.menuItem(path: [path[0]], runtime: runtime) else { return false }
            _ = AXHelpers.performAction(top, kAXPressAction as String, runtime: runtime.ax)
            usleep(400_000)
            guard enabled() else { AXMouseHelper.pressEscape(); return false }
        }
        return AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax)
    }

    /// Exactly these regions selected (Deselect All, then `AXSelected` on each), read back.
    static func vocalSelectExactly(_ names: Set<String>, index: Int, tempo: Double,
                                   runtime: AXLogicProElements.Runtime = .production) -> [VocalRegionItem]? {
        guard let deselect = AXLogicProElements.menuItem(identifier: "deselectAll:", inMenuBar: AXLocalePolicy.editMenuBar, runtime: runtime) else { return nil }
        _ = AXHelpers.performAction(deselect, kAXPressAction as String, runtime: runtime.ax)
        usleep(150_000)
        guard let regions = vocalTrackRegions(index: index, tempo: tempo, runtime: runtime) else { return nil }
        let targets = regions.filter { names.contains($0.name) }
        guard targets.count == names.count else { return nil }
        for t in targets { _ = AXHelpers.setAttribute(t.element, kAXSelectedAttribute, kCFBooleanTrue, runtime: runtime.ax) }
        usleep(200_000)
        guard let after = vocalTrackRegions(index: index, tempo: tempo, runtime: runtime) else { return nil }
        let selected = Set(after.filter(\.selected).map(\.name))
        return selected == names ? after.filter { names.contains($0.name) } : nil
    }

    private static func logicWindowTitles(runtime: AXLogicProElements.Runtime) -> [String] {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return [] }
        let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute as String, runtime: runtime.ax) ?? []
        return windows.compactMap { AXHelpers.getTitle($0, runtime: runtime.ax) }
    }

    /// Navigate > Go To > Position…, the position typed into its focused field, Return; true when
    /// the dialog opened and closed again. The caller reads the effect back (a split's boundary).
    static func vocalGoTo(_ position: String, runtime: AXLogicProElements.Runtime = .production) -> Bool {
        guard vocalPressMenu(["Navigate", "Go To", "Position\u{2026}"], runtime: runtime) else { return false }
        var opened = false
        for _ in 0..<15 {
            usleep(100_000)
            if logicWindowTitles(runtime: runtime).contains("Go To Position") { opened = true; break }
        }
        guard opened else { return false }
        AXMouseHelper.typeText(position.replacingOccurrences(of: ".", with: " "))
        AXMouseHelper.pressReturn()
        for _ in 0..<15 {
            usleep(100_000)
            if !logicWindowTitles(runtime: runtime).contains("Go To Position") { return true }
        }
        AXMouseHelper.pressEscape()
        return false
    }

    /// A drag on the region's lower-left (or lower-right) corner by `dx` points. Only a region
    /// that is on screen can be dragged; the caller reads the new edge back.
    static func vocalDragCorner(_ region: VocalRegionItem, left: Bool, dx: CGFloat,
                                runtime: AXLogicProElements.Runtime = .production) -> Bool {
        guard let frame = region.frame, let window = AXLogicProElements.mainWindow(runtime: runtime),
              let wp = AXHelpers.getPosition(window, runtime: runtime.ax),
              let ws = AXHelpers.getSize(window, runtime: runtime.ax) else { return false }
        let x = left ? frame.minX + 1 : frame.maxX - 1
        let y = frame.maxY - 4
        let visible = CGRect(origin: wp, size: ws).insetBy(dx: 4, dy: 4)
        guard visible.contains(CGPoint(x: x, y: y)), visible.contains(CGPoint(x: x + dx, y: y)) else { return false }
        return AXMouseHelper.drag(from: CGPoint(x: x, y: y), to: CGPoint(x: x + dx, y: y))
    }

    // MARK: - Region inspector fades

    struct VocalFades: Equatable {
        var fadeIn: Double
        var fadeOut: Double
        var type: String
    }

    private static func inspectorControls(runtime: AXLogicProElements.Runtime)
        -> (fadeIn: AXUIElement, fadeOut: AXUIElement, type: AXUIElement)? {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime) else { return nil }
        let all = AXHelpers.findAllDescendants(of: window, role: nil, maxDepth: 12, runtime: runtime.ax)
        func row(_ label: AXUIElement, role: String) -> AXUIElement? {
            guard let lp = AXHelpers.getPosition(label, runtime: runtime.ax) else { return nil }
            return all.first { e in
                guard AXHelpers.getRole(e, runtime: runtime.ax) == role,
                      let p = AXHelpers.getPosition(e, runtime: runtime.ax) else { return false }
                return abs(p.y - lp.y) < 3 && p.x > lp.x + 20 && p.x < lp.x + 200
            }
        }
        func label(_ role: String, _ text: String) -> [AXUIElement] {
            // The inspector's row labels carry their text as the value (measured on 12.4).
            all.filter { AXHelpers.getRole($0, runtime: runtime.ax) == role
                && (AXHelpers.getDescription($0, runtime: runtime.ax) == text || AXHelpers.getTitle($0, runtime: runtime.ax) == text
                    || (AXHelpers.getValue($0, runtime: runtime.ax) as? String) == text) }
        }
        let fadeInLabels = label(kAXPopUpButtonRole as String, "Fade-In")
        let fadeOutLabels = label(kAXPopUpButtonRole as String, "Fade-Out")
        guard fadeInLabels.count == 1, fadeOutLabels.count == 1,
              let outY = AXHelpers.getPosition(fadeOutLabels[0], runtime: runtime.ax)?.y,
              let fadeIn = row(fadeInLabels[0], role: kAXSliderRole as String),
              let fadeOut = row(fadeOutLabels[0], role: kAXSliderRole as String) else { return nil }
        // "Type:" is the row right below Fade-Out.
        let typeLabel = label(kAXTextFieldRole as String, "Type:").first {
            guard let y = AXHelpers.getPosition($0, runtime: runtime.ax)?.y else { return false }
            return y > outY && y < outY + 30
        }
        guard let typeLabel, let type = row(typeLabel, role: kAXPopUpButtonRole as String) else { return nil }
        return (fadeIn, fadeOut, type)
    }

    static func vocalReadFades(runtime: AXLogicProElements.Runtime = .production) -> VocalFades? {
        guard let c = inspectorControls(runtime: runtime),
              let i = AXValueExtractors.extractSliderValue(c.fadeIn, runtime: runtime.ax),
              let o = AXValueExtractors.extractSliderValue(c.fadeOut, runtime: runtime.ax) else { return nil }
        let type = (AXHelpers.getValue(c.type, runtime: runtime.ax) as? String) ?? AXHelpers.getTitle(c.type, runtime: runtime.ax) ?? ""
        return VocalFades(fadeIn: i, fadeOut: o, type: type)
    }

    /// For the ONE selected region; the caller reads the result back.
    static func vocalWriteFades(_ want: VocalFades, runtime: AXLogicProElements.Runtime = .production) {
        guard let c = inspectorControls(runtime: runtime), let now = vocalReadFades(runtime: runtime) else { return }
        if now.type != want.type {
            _ = AXHelpers.performAction(c.type, kAXPressAction as String, runtime: runtime.ax)
            usleep(300_000)
            let items = AXHelpers.findAllDescendants(of: c.type, role: kAXMenuItemRole as String, maxDepth: 4, runtime: runtime.ax)
            if let item = items.first(where: { (AXHelpers.getTitle($0, runtime: runtime.ax) ?? "").hasPrefix(want.type + " ")
                || AXHelpers.getTitle($0, runtime: runtime.ax) == want.type }) {
                _ = AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax)
            } else {
                AXMouseHelper.pressEscape()
            }
            usleep(200_000)
        }
        if now.fadeIn != want.fadeIn {
            _ = AXHelpers.setAttribute(c.fadeIn, kAXValueAttribute, NSNumber(value: want.fadeIn), runtime: runtime.ax)
        }
        if now.fadeOut != want.fadeOut {
            _ = AXHelpers.setAttribute(c.fadeOut, kAXValueAttribute, NSNumber(value: want.fadeOut), runtime: runtime.ax)
        }
        usleep(150_000)
    }

    // MARK: - Colours

    /// The selected regions of the track take its colour: the Tracks area's Functions > Color
    /// Regions/Cells by Track Color, with the track's own regions selected by a header click.
    static func vocalColorTrackRegionsByTrack(index: Int, tempo: Double, runtime: AXLogicProElements.Runtime = .production) -> Result<String, VocalStepError> {
        guard vocalSelectTrack(index: index, tempo: tempo, runtime: runtime),
              let header = AXLogicProElements.findTrackHeader(at: index, runtime: runtime) else { return .failure(.init("track_not_selected")) }
        let row = tracksAreaMenuRow(anchor: header, runtime: runtime)
        guard row.count >= 3 else { return .failure(.init("functions_menu_not_found (\(row.count) buttons)")) }
        let before = readTrackColorUndoWitness(runtime: runtime).title
        var items: [AXUIElement] = []
        // The menu does not always open on the first press right after the header click.
        for _ in 0..<3 where items.isEmpty {
            _ = AXHelpers.performAction(row[1], kAXPressAction as String, runtime: runtime.ax)
            for _ in 0..<10 {
                usleep(100_000)
                items = AXHelpers.findAllDescendants(of: row[1], role: kAXMenuItemRole as String, maxDepth: 4, runtime: runtime.ax)
                    .filter { AXLocalePolicy.colorRegionsByTrackColorMenuItem.matches(AXHelpers.getTitle($0, runtime: runtime.ax)) }
                if !items.isEmpty { break }
            }
            if items.isEmpty { AXMouseHelper.pressEscape(); usleep(300_000) }
        }
        guard items.count == 1 else { AXMouseHelper.pressEscape(); return .failure(.init("menu_item_count_\(items.count)")) }
        let pressed = AXHelpers.performAction(items[0], kAXPressAction as String, runtime: runtime.ax)
        usleep(300_000)
        let title = readTrackColorUndoWitness(runtime: runtime).title ?? "unread"
        guard pressed else { return .failure(.init("press_failed, undo: \(title)")) }
        // Regions already in their track's colour leave no Undo step: an unchanged title is that.
        return .success(title == before ? "" : title)
    }

    struct VocalStepError: Error { let reason: String; init(_ reason: String) { self.reason = reason } }

    /// One region (selected alone by the caller) coloured through View > Colors.
    static func vocalColorSelectedRegion(_ region: VocalRegionItem, swatch: TrackColorSwatch,
                                         runtime: AXLogicProElements.Runtime = .production) -> String? {
        _ = AXHelpers.setAttribute(region.element, kAXFocusedAttribute, kCFBooleanTrue, runtime: runtime.ax)
        var evidence: [String: Any] = [:]
        switch clickPaletteSwatch(menuPath: AXLocalePolicy.viewColorsMenuPath, menuName: "View > Colors",
                                  row: swatch.row, column: swatch.column, operation: "track.prepare_vocal",
                                  evidence: &evidence, runtime: runtime) {
        case .refused: return nil
        case .clicked: break
        }
        return readTrackColorUndoWitness(runtime: runtime).title
    }
}
