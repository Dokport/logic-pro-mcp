import ApplicationServices; import AppKit
let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first!.processIdentifier
let app = AXUIElementCreateApplication(pid)
func a(_ e: AXUIElement,_ n:String)->CFTypeRef?{var v:CFTypeRef?;AXUIElementCopyAttributeValue(e,n as CFString,&v);return v}
func kids(_ e: AXUIElement)->[AXUIElement]{ (a(e,"AXChildren") as? [AXUIElement]) ?? [] }
func find(_ e: AXUIElement, _ pred:(AXUIElement)->Bool) -> AXUIElement? { if pred(e) { return e }; for k in kids(e) { if let f = find(k,pred) { return f } }; return nil }
let w = (a(app,"AXWindows") as! [AXUIElement]).first{ ((a($0,"AXTitle") as? String) ?? "").hasSuffix("- Tracks") }!
let hdr = find(w){ (a($0,"AXDescription") as? String) == "Tracks header" }!
let row = kids(hdr).filter{ (a($0,"AXRole") as? String) == "AXLayoutItem" }[Int(CommandLine.arguments[1])!]
let m = kids(row).first{ (a($0,"AXDescription") as? String) == "Mute" }!
var p = CGPoint.zero, s = CGSize.zero
AXValueGetValue(a(m,"AXPosition") as! AXValue, .cgPoint, &p); AXValueGetValue(a(m,"AXSize") as! AXValue, .cgSize, &s)
print("before", a(m,"AXValue")!)
let c = CGPoint(x: p.x + s.width/2, y: p.y + s.height/2)
let src = CGEventSource(stateID: .combinedSessionState)
CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: c, mouseButton: .left)!.post(tap: .cghidEventTap); usleep(80000)
for t in [CGEventType.leftMouseDown, .leftMouseUp] { let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: c, mouseButton: .left)!; e.setIntegerValueField(.mouseEventClickState, value: 1); e.post(tap: .cghidEventTap); usleep(80000) }
usleep(300000); print("after", a(m,"AXValue")!)
