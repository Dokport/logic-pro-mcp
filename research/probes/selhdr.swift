// selhdr i j ... : set AXSelectedChildren of the "Tracks header" group to those header indices, print what reads back
import ApplicationServices; import AppKit
let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first!.processIdentifier
let app = AXUIElementCreateApplication(pid)
func a(_ e: AXUIElement,_ n:String)->CFTypeRef?{var v:CFTypeRef?;AXUIElementCopyAttributeValue(e,n as CFString,&v);return v}
func kids(_ e: AXUIElement)->[AXUIElement]{ (a(e,"AXChildren") as? [AXUIElement]) ?? [] }
func find(_ e: AXUIElement, _ pred:(AXUIElement)->Bool) -> AXUIElement? { if pred(e) { return e }; for k in kids(e) { if let f = find(k,pred) { return f } }; return nil }
let w = (a(app,"AXWindows") as! [AXUIElement]).first{ ((a($0,"AXTitle") as? String) ?? "").hasSuffix("- Tracks") }!
let hdr = find(w){ (a($0,"AXDescription") as? String) == "Tracks header" }!
let rows = kids(hdr).filter{ (a($0,"AXRole") as? String) == "AXLayoutItem" }
let want = CommandLine.arguments.dropFirst().map{ rows[Int($0)!] }
print("set", AXUIElementSetAttributeValue(hdr, "AXSelectedChildren" as CFString, want as CFArray).rawValue)
usleep(300000)
let sel = (a(hdr,"AXSelectedChildren") as? [AXUIElement]) ?? []
print("selected:", sel.map{ a($0,"AXDescription") as? String ?? "?" })
