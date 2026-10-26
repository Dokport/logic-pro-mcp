// menubtn <desc> : AXPress the Mixer's local menu button with that description
import ApplicationServices; import AppKit
let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first!.processIdentifier
let app = AXUIElementCreateApplication(pid)
func a(_ e: AXUIElement,_ n:String)->CFTypeRef?{var v:CFTypeRef?;AXUIElementCopyAttributeValue(e,n as CFString,&v);return v}
func kids(_ e: AXUIElement)->[AXUIElement]{ (a(e,"AXChildren") as? [AXUIElement]) ?? [] }
func find(_ e: AXUIElement, _ pred:(AXUIElement)->Bool) -> AXUIElement? { if pred(e) { return e }; for k in kids(e) { if let f = find(k,pred) { return f } }; return nil }
let w = (a(app,"AXWindows") as! [AXUIElement]).first{ ((a($0,"AXTitle") as? String) ?? "").hasSuffix("- Tracks") }!
let b = find(w){ (a($0,"AXRole") as? String) == "AXMenuButton" && (a($0,"AXDescription") as? String) == CommandLine.arguments[1] }!
print(AXUIElementPerformAction(b, "AXPress" as CFString).rawValue)
