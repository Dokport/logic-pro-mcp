// press <strip desc> <control desc>  — AXPress a control inside a Mixer strip of the main window, then dump any open menu.
import ApplicationServices; import AppKit
let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first!.processIdentifier
let app = AXUIElementCreateApplication(pid)
func a(_ e: AXUIElement,_ n:String)->CFTypeRef?{var v:CFTypeRef?;AXUIElementCopyAttributeValue(e,n as CFString,&v);return v}
func kids(_ e: AXUIElement)->[AXUIElement]{ (a(e,"AXChildren") as? [AXUIElement]) ?? [] }
func find(_ e: AXUIElement, _ pred:(AXUIElement)->Bool) -> AXUIElement? { if pred(e) { return e }; for k in kids(e) { if let f = find(k,pred) { return f } }; return nil }
let strip = CommandLine.arguments[1], ctl = CommandLine.arguments[2]
let w = (a(app,"AXWindows") as! [AXUIElement]).first{ ((a($0,"AXTitle") as? String) ?? "").hasSuffix("- Tracks") }!
let mixer = find(w){ (a($0,"AXRole") as? String) == "AXLayoutArea" && (a($0,"AXDescription") as? String) == "Mixer" && ((a($0,"AXSize") != nil)) && kids($0).count > 3 }!
let s = kids(mixer).first{ (a($0,"AXDescription") as? String) == strip }!
let c = kids(s).first{ (a($0,"AXDescription") as? String) == ctl }!
print("press", AXUIElementPerformAction(c, "AXPress" as CFString).rawValue)
