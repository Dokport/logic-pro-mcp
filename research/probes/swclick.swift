import ApplicationServices; import AppKit
let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first!.processIdentifier
let app = AXUIElementCreateApplication(pid)
func a(_ e: AXUIElement,_ n:String)->CFTypeRef?{var v:CFTypeRef?;AXUIElementCopyAttributeValue(e,n as CFString,&v);return v}
let w = (a(app,"AXWindows") as! [AXUIElement]).first{ (a($0,"AXTitle") as? String) == "Color" }!
let g2 = (a((a(w,"AXChildren") as! [AXUIElement])[1],"AXChildren") as! [AXUIElement])[0]
let kids = a(g2,"AXChildren") as! [AXUIElement]
let k = kids[Int(CommandLine.arguments[1])!]
var p = CGPoint.zero, s = CGSize.zero
AXValueGetValue(a(k,"AXPosition") as! AXValue, .cgPoint, &p); if let sv = a(k,"AXSize") { AXValueGetValue(sv as! AXValue, .cgSize, &s) } else { s = CGSize(width: 26, height: 18) }
let c = CGPoint(x: p.x + s.width/2, y: p.y + s.height/2)
print("click", c, s)
let src = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: c, mouseButton: .left)!.post(tap: .cghidEventTap)
usleep(60000)
CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: c, mouseButton: .left)!.post(tap: .cghidEventTap)
