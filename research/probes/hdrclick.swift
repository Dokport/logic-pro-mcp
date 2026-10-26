// hdrclick <index> [shift|cmd] : CGEvent click on the empty area of an AX-located track header (right of the buttons)
import ApplicationServices; import AppKit
let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first!.processIdentifier
let app = AXUIElementCreateApplication(pid)
func a(_ e: AXUIElement,_ n:String)->CFTypeRef?{var v:CFTypeRef?;AXUIElementCopyAttributeValue(e,n as CFString,&v);return v}
func kids(_ e: AXUIElement)->[AXUIElement]{ (a(e,"AXChildren") as? [AXUIElement]) ?? [] }
func find(_ e: AXUIElement, _ pred:(AXUIElement)->Bool) -> AXUIElement? { if pred(e) { return e }; for k in kids(e) { if let f = find(k,pred) { return f } }; return nil }
let w = (a(app,"AXWindows") as! [AXUIElement]).first{ ((a($0,"AXTitle") as? String) ?? "").hasSuffix("- Tracks") }!
let hdr = find(w){ (a($0,"AXDescription") as? String) == "Tracks header" }!
let rows = kids(hdr).filter{ (a($0,"AXRole") as? String) == "AXLayoutItem" }
let row = rows[Int(CommandLine.arguments[1])!]
var p = CGPoint.zero, s = CGSize.zero
let name = kids(row).first{ (a($0,"AXRole") as? String) == "AXTextField" }!
AXValueGetValue(a(name,"AXPosition") as! AXValue, .cgPoint, &p); AXValueGetValue(a(name,"AXSize") as! AXValue, .cgSize, &s)
let c = CGPoint(x: p.x + s.width - 30, y: p.y + s.height / 2)
var flags: CGEventFlags = []
if CommandLine.arguments.count > 2 { flags = CommandLine.arguments[2] == "shift" ? .maskShift : .maskCommand }
let src = CGEventSource(stateID: .hidSystemState)
for t in [CGEventType.leftMouseDown, .leftMouseUp] { let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: c, mouseButton: .left)!; e.flags = flags; e.post(tap: .cghidEventTap); usleep(50000) }
usleep(300000)
print("selected:", rows.enumerated().filter{ ((a($0.element,"AXSelected") as? NSNumber)?.boolValue ?? false) }.map{ $0.offset })
