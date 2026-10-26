import ApplicationServices; import AppKit
let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first!.processIdentifier
let app = AXUIElementCreateApplication(pid)
func a(_ e: AXUIElement,_ n:String)->CFTypeRef?{var v:CFTypeRef?;AXUIElementCopyAttributeValue(e,n as CFString,&v);return v}
func names(_ e: AXUIElement)->[String]{var n:CFArray?;AXUIElementCopyAttributeNames(e,&n);return (n as? [String]) ?? []}
let wins = a(app,"AXWindows") as! [AXUIElement]
let w = wins.first{ (a($0,"AXTitle") as? String) == "Color" }!
let g2 = (a((a(w,"AXChildren") as! [AXUIElement])[1],"AXChildren") as! [AXUIElement])[0]
let kids = a(g2,"AXChildren") as! [AXUIElement]
print("swatch attrs:", names(kids[5]))
print("group attrs:", names(g2))
let idx = Int(CommandLine.arguments[1])!
let r = AXUIElementPerformAction(kids[idx], "AXPress" as CFString)
print("press", idx, r.rawValue)
usleep(400000)
let sel = a(g2,"AXSelectedChildren") as? [AXUIElement] ?? []
print("selected:", sel.map{ kids.firstIndex(of:$0) ?? -1 })
