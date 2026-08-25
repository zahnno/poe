// Draws Poe's app icon: a glowing yellow lantern on white.
// Run with:  swift tools/make_icon.swift <output-dir>
import AppKit

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let metal      = rgb(0.145, 0.118, 0.086)          // warm charcoal frame
let metalLight = rgb(0.255, 0.212, 0.157)
let amber      = rgb(1.000, 0.706, 0.145)
let amberDeep  = rgb(0.980, 0.573, 0.020)
let core       = rgb(1.000, 0.965, 0.812)
let sRGB       = CGColorSpace(name: CGColorSpace.sRGB)!

/// The lantern, drawn in a 1024×1024 top-left origin space.
func drawLantern(in context: CGContext) {
    // --- glow behind the glass -------------------------------------------------
    let heart = CGPoint(x: 512, y: 486)
    let halo = CGGradient(colorsSpace: sRGB,
                          colors: [amber.copy(alpha: 0.42)!,
                                   amber.copy(alpha: 0.10)!,
                                   amber.copy(alpha: 0)!] as CFArray,
                          locations: [0, 0.42, 1])!
    context.drawRadialGradient(halo, startCenter: heart, startRadius: 0,
                               endCenter: heart, endRadius: 330, options: [])

    // --- handle ----------------------------------------------------------------
    let handle = CGMutablePath()
    handle.addArc(center: CGPoint(x: 512, y: 246), radius: 86,
                  startAngle: .pi, endAngle: 0, clockwise: false)
    context.addPath(handle)
    context.setStrokeColor(metal)
    context.setLineWidth(26)
    context.setLineCap(.round)
    context.strokePath()

    // --- top cap ---------------------------------------------------------------
    let cap = CGMutablePath()
    cap.move(to: CGPoint(x: 452, y: 236))
    cap.addLine(to: CGPoint(x: 572, y: 236))
    cap.addLine(to: CGPoint(x: 648, y: 320))
    cap.addLine(to: CGPoint(x: 376, y: 320))
    cap.closeSubpath()
    context.addPath(cap)
    context.setFillColor(metal)
    context.fillPath()

    // --- glass: a barrel with bulging sides ------------------------------------
    let glass = CGMutablePath()
    glass.move(to: CGPoint(x: 402, y: 336))
    glass.addCurve(to: CGPoint(x: 402, y: 664),
                   control1: CGPoint(x: 344, y: 448),
                   control2: CGPoint(x: 344, y: 552))
    glass.addLine(to: CGPoint(x: 622, y: 664))
    glass.addCurve(to: CGPoint(x: 622, y: 336),
                   control1: CGPoint(x: 680, y: 552),
                   control2: CGPoint(x: 680, y: 448))
    glass.closeSubpath()

    context.saveGState()
    context.setShadow(offset: .zero, blur: 70, color: amberDeep.copy(alpha: 0.75))
    context.addPath(glass)
    context.setFillColor(amber)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(glass)
    context.clip()
    let fill = CGGradient(colorsSpace: sRGB,
                          colors: [core, amber, amberDeep] as CFArray,
                          locations: [0, 0.5, 1])!
    context.drawLinearGradient(fill, start: CGPoint(x: 402, y: 336),
                               end: CGPoint(x: 622, y: 664), options: [])

    // The flame at the heart of it.
    let flameGlow = CGGradient(colorsSpace: sRGB,
                               colors: [rgb(1, 1, 1, 0.95), core.copy(alpha: 0.35)!, core.copy(alpha: 0)!] as CFArray,
                               locations: [0, 0.5, 1])!
    context.drawRadialGradient(flameGlow, startCenter: heart, startRadius: 0,
                               endCenter: heart, endRadius: 132, options: [])

    // Two frame bars across the panes.
    context.setFillColor(metal.copy(alpha: 0.55)!)
    context.fill(CGRect(x: 466, y: 336, width: 14, height: 328))
    context.fill(CGRect(x: 546, y: 336, width: 14, height: 328))
    context.restoreGState()

    // --- rings, base, foot -----------------------------------------------------
    context.setFillColor(metal)
    context.fill(CGRect(x: 372, y: 318, width: 280, height: 34))
    context.fill(CGRect(x: 386, y: 648, width: 252, height: 34))

    let base = CGMutablePath()
    base.move(to: CGPoint(x: 396, y: 682))
    base.addLine(to: CGPoint(x: 628, y: 682))
    base.addLine(to: CGPoint(x: 596, y: 752))
    base.addLine(to: CGPoint(x: 428, y: 752))
    base.closeSubpath()
    context.addPath(base)
    context.fillPath()

    context.setFillColor(metalLight)
    context.fill(CGRect(x: 452, y: 752, width: 120, height: 28))
}

func draw(size: CGFloat) -> Data {
    guard let context = CGContext(data: nil, width: Int(size), height: Int(size),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("no context") }

    context.scaleBy(x: size / 1024, y: size / 1024)
    context.setAllowsAntialiasing(true)

    // macOS icons sit inside a rounded square with breathing room around it.
    let inset: CGFloat = 100
    let rect = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let squircle = CGPath(roundedRect: rect, cornerWidth: 190, cornerHeight: 190, transform: nil)

    context.saveGState()
    context.addPath(squircle)
    context.clip()
    context.setFillColor(rgb(1, 1, 1))
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    // Flip to a top-left origin so the lantern reads the way it is drawn.
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)
    drawLantern(in: context)
    context.restoreGState()

    // A whisper of a rim so the icon still has an edge on a white desktop.
    context.addPath(squircle)
    context.setStrokeColor(rgb(0.62, 0.55, 0.44, 0.28))
    context.setLineWidth(3)
    context.strokePath()

    guard let image = context.makeImage() else { fatalError("no image") }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: outputDir).appendingPathComponent("Poe.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (name, size) in [("icon_16x16.png", CGFloat(16)), ("icon_16x16@2x.png", 32),
                     ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
                     ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
                     ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
                     ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)] {
    try! draw(size: size).write(to: iconset.appendingPathComponent(name))
}
print("iconset written to \(iconset.path)")
