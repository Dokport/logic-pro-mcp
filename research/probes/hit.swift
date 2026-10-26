import ApplicationServices; import AppKit
let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first!.processIdentifier
let app = AXUIElementCreateApplication(pid)
func a(_ e: AXUIElement,_ n:String)->CFTypeRef?{var v:CFTypeRef?;AXUIElementCopyAttributeValue(e,n as CFString,&v);return v}
var el: AXUIElement?
let x = Float(CommandLine.arguments[1])!, y = Float(CommandLine.arguments[2])!
print(AXUIElementCopyElementAtPosition(app, x, y, &el).rawValue, el.map{ "\(a($0,"AXRole") ?? "nil" as CFString) \(a($0,"AXDescription") ?? "nil" as CFString)" } ?? "none")
print("mouse", NSEvent.mouseLocation, "screens", NSScreen.screens.map{ $0.frame })
