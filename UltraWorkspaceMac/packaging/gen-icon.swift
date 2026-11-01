import AppKit

let N = 1024
let img = NSImage(size: NSSize(width: N, height: N))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()

// Rounded "squircle" background
let r: CGFloat = 230
let bg = CGMutablePath()
let rect = CGRect(x: 0, y: 0, width: N, height: N)
bg.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
ctx.addPath(bg); ctx.clip()

// Vertical gradient background (deep indigo -> near black)
let grad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.20, green: 0.17, blue: 0.42, alpha: 1),
    CGColor(red: 0.07, green: 0.06, blue: 0.13, alpha: 1)
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: N), end: CGPoint(x: 0, y: 0), options: [])

// Soft top glow
let glow = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.45, green: 0.40, blue: 0.95, alpha: 0.55),
    CGColor(red: 0.45, green: 0.40, blue: 0.95, alpha: 0.0)
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: N/2, y: Int(Double(N)*0.86)), startRadius: 0,
                       endCenter: CGPoint(x: N/2, y: Int(Double(N)*0.86)), endRadius: CGFloat(N)*0.6, options: [])

// The UltraBar: horizontal silver bar
let barW: CGFloat = 760, barH: CGFloat = 190
let barX = (CGFloat(N) - barW)/2, barY = (CGFloat(N) - barH)/2
let barRect = CGRect(x: barX, y: barY, width: barW, height: barH)
let barPath = CGPath(roundedRect: barRect, cornerWidth: 44, cornerHeight: 44, transform: nil)
ctx.saveGState()
ctx.addPath(barPath)
// drop shadow
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: CGColor(red: 0,green:0,blue:0,alpha:0.5))
ctx.setFillColor(CGColor(red: 0.88, green: 0.89, blue: 0.93, alpha: 1))
ctx.fillPath()
ctx.restoreGState()
// subtle vertical sheen on the bar
ctx.saveGState()
ctx.addPath(barPath); ctx.clip()
let sheen = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 1,green:1,blue:1,alpha:0.9),
    CGColor(red: 0.78,green:0.80,blue:0.86,alpha:1),
    CGColor(red: 0.62,green:0.64,blue:0.72,alpha:1)
] as CFArray, locations: [0,0.5,1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: barY+barH), end: CGPoint(x: 0, y: barY), options: [])
ctx.restoreGState()

let cy = CGFloat(N)/2
// KnobKey: circle on the left of the bar
let knobR: CGFloat = 58
ctx.setFillColor(CGColor(red: 0.30, green: 0.31, blue: 0.37, alpha: 1))
ctx.fillEllipse(in: CGRect(x: barX+42, y: cy-knobR, width: knobR*2, height: knobR*2))
ctx.setFillColor(CGColor(red: 0.45, green: 0.46, blue: 0.52, alpha: 1))
ctx.fillEllipse(in: CGRect(x: barX+42+26, y: cy-knobR+26, width: (knobR-26)*2, height: (knobR-26)*2))

// CoreBar screen: central dark block with gradient accent
let scX = barX+200, scW: CGFloat = 300, scH: CGFloat = 120
let scRect = CGRect(x: scX, y: cy-scH/2, width: scW, height: scH)
let scPath = CGPath(roundedRect: scRect, cornerWidth: 22, cornerHeight: 22, transform: nil)
ctx.addPath(scPath); ctx.saveGState(); ctx.clip()
let accent = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.28, green: 0.55, blue: 1.0, alpha: 1),
    CGColor(red: 0.55, green: 0.33, blue: 0.95, alpha: 1)
] as CFArray, locations: [0,1])!
ctx.drawLinearGradient(accent, start: CGPoint(x: scX, y: cy), end: CGPoint(x: scX+scW, y: cy), options: [])
// little "widgets" hint: three rounded bars
ctx.setFillColor(CGColor(red:1,green:1,blue:1,alpha:0.85))
for i in 0..<3 {
    let wx = scX + 30 + CGFloat(i)*95
    ctx.addPath(CGPath(roundedRect: CGRect(x: wx, y: cy-34, width: 66, height: 68), cornerWidth: 12, cornerHeight: 12, transform: nil))
}
ctx.setFillColor(CGColor(red:1,green:1,blue:1,alpha:0.22)); ctx.fillPath()
ctx.restoreGState()

// VivoCube: rounded square with a bright round screen, right of center
let vcX = scX+scW+40
ctx.setFillColor(CGColor(red: 0.30, green: 0.31, blue: 0.37, alpha: 1))
ctx.addPath(CGPath(roundedRect: CGRect(x: vcX, y: cy-72, width: 144, height: 144), cornerWidth: 28, cornerHeight: 28, transform: nil)); ctx.fillPath()
let vcGrad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.30, green: 0.80, blue: 0.95, alpha: 1),
    CGColor(red: 0.30, green: 0.45, blue: 0.95, alpha: 1)] as CFArray, locations:[0,1])!
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: vcX+22, y: cy-50, width: 100, height: 100)); ctx.clip()
ctx.drawLinearGradient(vcGrad, start: CGPoint(x: vcX, y: cy+50), end: CGPoint(x: vcX+100, y: cy-50), options: [])
ctx.restoreGState()

// DotKey: two small buttons on the far right
ctx.setFillColor(CGColor(red: 0.30, green: 0.31, blue: 0.37, alpha: 1))
ctx.fillEllipse(in: CGRect(x: barX+barW-120, y: cy+6, width: 48, height: 48))
ctx.fillEllipse(in: CGRect(x: barX+barW-120, y: cy-54, width: 48, height: 48))
ctx.addPath(CGPath(roundedRect: CGRect(x: barX+barW-62, y: cy-54, width: 40, height: 108), cornerWidth: 20, cornerHeight: 20, transform: nil)); ctx.fillPath()

img.unlockFocus()

let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote icon")
