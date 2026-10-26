import ApplicationServices; import AppKit
let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first!.processIdentifier
let app = AXUIElementCreateApplication(pid)
func a(_ e: AXUIElement,_ n:String)->CFTypeRef?{var v:CFTypeRef?;AXUIElementCopyAttributeValue(e,n as CFString,&v);return v}
let w = (a(app,"AXWindows") as! [AXUIElement]).first{ (a($0,"AXTitle") as? String) == "Color" }!
let g2 = (a((a(w,"AXChildren") as! [AXUIElement])[1],"AXChildren") as! [AXUIElement])[0]
for (i,k) in (a(g2,"AXChildren") as! [AXUIElement]).enumerated() { var p = CGPoint.zero; AXValueGetValue(a(k,"AXPosition") as! AXValue, .cgPoint, &p); print(i, Int(p.x), Int(p.y), a(k,"AXSize") != nil, a(k,"AXFrame") != nil) }
