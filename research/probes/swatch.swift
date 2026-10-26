import ApplicationServices; import AppKit
let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first!.processIdentifier
let app = AXUIElementCreateApplication(pid)
func a(_ e: AXUIElement,_ n:String)->(AXError,CFTypeRef?){var v:CFTypeRef?;let r=AXUIElementCopyAttributeValue(e,n as CFString,&v);return (r,v)}
let wins = a(app,"AXWindows").1 as! [AXUIElement]
let w = wins.first{ (a($0,"AXTitle").1 as? String) == "Color" }!
let g = (a(w,"AXChildren").1 as! [AXUIElement])[1]
let g2 = (a(g,"AXChildren").1 as! [AXUIElement])[0]
let kids = a(g2,"AXChildren").1 as! [AXUIElement]
print("count", kids.count)
for (i,k) in kids.enumerated() where i < 4 || i > 92 {
  var line = "\(i):"
  for n in ["AXRole","AXRoleDescription","AXTitle","AXDescription","AXValue","AXHelp","AXPosition","AXEnabled"] { let (r,v)=a(k,n); line += " \(n)=\(r.rawValue):\(v.map{"\($0)"} ?? "nil")" }
  print(line)
}
let sel = a(g2,"AXSelectedChildren"); print("selectedChildren", sel.0.rawValue, (sel.1 as? [AXUIElement])?.count ?? -1)
if let s = sel.1 as? [AXUIElement], let f = s.first { print("sel index", kids.firstIndex(of: f) ?? -1) }
// values over all
var vals:[String:Int]=[:]; for k in kids { let v = a(k,"AXValue").1.map{"\($0)"} ?? "nil"; vals[v, default:0]+=1 }; print(vals)
