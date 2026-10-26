import AppKit
let img = NSImage(contentsOfFile: CommandLine.arguments[1])!
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let W = rep.pixelsWide, H = rep.pixelsHigh
print("size", W, H)
func px(_ x: Int, _ y: Int) -> (Int,Int,Int) { let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!; return (Int(c.redComponent*255), Int(c.greenComponent*255), Int(c.blueComponent*255)) }
// find swatch row/col bands: a pixel is "swatch" when saturation-ish distance from background (~28,28,28) is large
func isSwatch(_ p:(Int,Int,Int)) -> Bool { abs(p.0-p.1)+abs(p.1-p.2)+abs(p.0-p.2) > 30 || max(p.0,p.1,p.2) > 70 }
// columns along the first row's centre line, rows along column 12
func bands(_ vals:[Bool]) -> [(Int,Int)] { var out:[(Int,Int)]=[]; var s = -1; for (i,v) in vals.enumerated() { if v && s<0 { s=i }; if !v && s>=0 { if i-s>8 { out.append((s,i-1)) }; s = -1 } }; if s>=0 { out.append((s,vals.count-1)) }; return out }
let rowsB = bands((0..<H).map{ isSwatch(px(W/2 + 60, $0)) })
print("rows", rowsB)
let y0 = (rowsB[0].0 + rowsB[0].1)/2
let colsB = bands((0..<W).map{ isSwatch(px($0, y0)) })
print("cols", colsB.count, colsB.first!, colsB.last!)
for (r, rb) in rowsB.enumerated() {
  let y = (rb.0+rb.1)/2
  var line: [String] = []
  for cb in colsB.suffix(24) { let x = (cb.0+cb.1)/2; let p = px(x, y); line.append(String(format: "%02X%02X%02X", p.0, p.1, p.2)) }
  print("row\(r+1)", line.joined(separator: " "))
}
