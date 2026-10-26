// ax-dump: dump Logic Pro's Accessibility tree for UI research (read-only, presses nothing).
//
//   ax-dump [--window <title-substring>|--focused|--menubar|--all] [--depth N] [--json] [--attrs]
//           [--match <text>]
//
// Every node prints role/subrole, title, description, value, identifier, help, frame and
// the AX actions it advertises. --attrs adds every attribute name with a settable marker,
// which is how a write channel is found. --match keeps only subtrees whose text contains
// <text> (case-insensitive), with their ancestor path.
import ApplicationServices
import AppKit
import Foundation

struct Options {
    var scope = "all"
    var windowFilter: String?
    var depth = 40
    var json = false
    var attrs = false
    var match: String?
}

func parseOptions() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let a = args.next() {
        switch a {
        case "--window": o.scope = "window"; o.windowFilter = args.next()
        case "--focused": o.scope = "focused"
        case "--menubar": o.scope = "menubar"
        case "--all": o.scope = "all"
        case "--depth": o.depth = Int(args.next() ?? "") ?? o.depth
        case "--json": o.json = true
        case "--attrs": o.attrs = true
        case "--match": o.match = args.next()?.lowercased()
        default:
            FileHandle.standardError.write("unknown argument \(a)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

func describe(_ v: CFTypeRef?) -> Any? {
    guard let v else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n }
    if CFGetTypeID(v) == AXValueGetTypeID() {
        let av = v as! AXValue
        switch AXValueGetType(av) {
        case .cgPoint: var p = CGPoint.zero; AXValueGetValue(av, .cgPoint, &p); return ["x": p.x, "y": p.y]
        case .cgSize: var s = CGSize.zero; AXValueGetValue(av, .cgSize, &s); return ["w": s.width, "h": s.height]
        case .cfRange: var r = CFRange(); AXValueGetValue(av, .cfRange, &r); return ["loc": r.location, "len": r.length]
        default: return "\(av)"
        }
    }
    if CFGetTypeID(v) == AXUIElementGetTypeID() { return "<element>" }
    if let a = v as? [Any] { return "<array \(a.count)>" }
    if let u = v as? URL { return u.absoluteString }
    return "\(v)"
}

func node(_ e: AXUIElement, options: Options) -> [String: Any] {
    var d: [String: Any] = [:]
    for (key, name) in [("role", kAXRoleAttribute), ("subrole", kAXSubroleAttribute), ("title", kAXTitleAttribute),
                        ("desc", kAXDescriptionAttribute), ("value", kAXValueAttribute), ("id", kAXIdentifierAttribute),
                        ("help", kAXHelpAttribute), ("pos", kAXPositionAttribute), ("size", kAXSizeAttribute),
                        ("selected", kAXSelectedAttribute), ("enabled", kAXEnabledAttribute)] {
        if let v = describe(attr(e, name)) { d[key] = v }
    }
    var actions: CFArray?
    if AXUIElementCopyActionNames(e, &actions) == .success, let a = actions as? [String], !a.isEmpty {
        d["actions"] = a
    }
    if options.attrs {
        var names: CFArray?
        if AXUIElementCopyAttributeNames(e, &names) == .success, let n = names as? [String] {
            d["attrs"] = n.map { name -> String in
                var settable = DarwinBoolean(false)
                AXUIElementIsAttributeSettable(e, name as CFString, &settable)
                return settable.boolValue ? "\(name)=" : name
            }
        }
    }
    return d
}

func children(_ e: AXUIElement) -> [AXUIElement] {
    (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func text(of d: [String: Any]) -> String {
    ["title", "desc", "value", "id", "help"].compactMap { d[$0].map { "\($0)" } }.joined(separator: " ").lowercased()
}

// Returns the rendered lines of this subtree, or [] when --match filters it out.
func walk(_ e: AXUIElement, depth: Int, options: Options, path: [String]) -> [[String: Any]] {
    var d = node(e, options: options)
    d["depth"] = depth
    var out: [[String: Any]] = []
    let selfMatches = options.match.map { text(of: d).contains($0) } ?? true
    var kids: [[String: Any]] = []
    if depth < options.depth {
        for c in children(e) {
            kids += walk(c, depth: depth + 1, options: options, path: path + [(d["role"] as? String) ?? "?"])
        }
    }
    if selfMatches || !kids.isEmpty {
        if options.match != nil, selfMatches { d["matched"] = true }
        out.append(d)
        out += kids
    }
    return out
}

func render(_ rows: [[String: Any]], json: Bool) {
    for r in rows {
        if json {
            let data = try! JSONSerialization.data(withJSONObject: r, options: [.sortedKeys])
            print(String(data: data, encoding: .utf8)!)
            continue
        }
        let indent = String(repeating: "  ", count: (r["depth"] as? Int) ?? 0)
        var parts = ["\(r["role"] ?? "?")" + (r["subrole"].map { "/\($0)" } ?? "")]
        for k in ["title", "desc", "value", "id", "help"] {
            if let v = r[k], "\(v)" != "" { parts.append("\(k)=\(String(reflecting: "\(v)"))") }
        }
        if let p = r["pos"] as? [String: Any], let s = r["size"] as? [String: Any] {
            parts.append("@\(p["x"]!),\(p["y"]!) \(s["w"]!)x\(s["h"]!)")
        }
        if let a = r["actions"] as? [String] { parts.append("actions=\(a.joined(separator: ","))") }
        if let s = r["selected"] { parts.append("selected=\(s)") }
        if let a = r["attrs"] as? [String] { parts.append("attrs=[\(a.joined(separator: ","))]") }
        if r["matched"] != nil { parts.append("<<MATCH") }
        print(indent + parts.joined(separator: " "))
    }
}

let options = parseOptions()
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write("Accessibility not granted to the responsible process\n".data(using: .utf8)!)
    exit(3)
}
guard let logic = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first else {
    FileHandle.standardError.write("Logic Pro is not running\n".data(using: .utf8)!)
    exit(4)
}
let app = AXUIElementCreateApplication(logic.processIdentifier)
AXUIElementSetMessagingTimeout(app, 5)

var roots: [AXUIElement] = []
switch options.scope {
case "focused":
    if let w = attr(app, kAXFocusedWindowAttribute) { roots = [w as! AXUIElement] }
case "menubar":
    if let m = attr(app, kAXMenuBarAttribute) { roots = [m as! AXUIElement] }
case "window":
    let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    roots = windows.filter { w in
        let t = (attr(w, kAXTitleAttribute) as? String) ?? ""
        return t.lowercased().contains(options.windowFilter?.lowercased() ?? "")
    }
default:
    roots = [app]
}
if roots.isEmpty {
    FileHandle.standardError.write("no matching root\n".data(using: .utf8)!)
    exit(5)
}
for r in roots {
    render(walk(r, depth: 0, options: options, path: []), json: options.json)
}
