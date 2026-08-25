// Builds Poe's app icon from the master artwork in assets/AppIcon.png — the lit
// lantern on its violet plate — masked into the macOS icon shape at every size.
//
// Run with:  swift tools/make_icon.swift <output-dir> [master.png]
import AppKit

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

let arguments = CommandLine.arguments
let outputDir = arguments.count > 1 ? arguments[1] : "."
let masterPath = arguments.count > 2
    ? arguments[2]
    : URL(fileURLWithPath: #filePath)                       // tools/make_icon.swift
        .deletingLastPathComponent()                        // tools/
        .deletingLastPathComponent()                        // repo root
        .appendingPathComponent("assets/AppIcon.png").path

guard let master = NSImage(contentsOfFile: masterPath),
      let tiff = master.tiffRepresentation,
      let masterRep = NSBitmapImageRep(data: tiff),
      let masterImage = masterRep.cgImage
else { fatalError("could not read master artwork at \(masterPath)") }

/// The artwork ships with its own plate inside a square canvas: the plate's rim
/// sits at 103/1024 on every side. We crop just inside that rim so none of the
/// backdrop behind it — or the rim itself — survives into the icon.
let plate = CGRect(x: 105, y: 105, width: 814, height: 814)
    .applying(CGAffineTransform(scaleX: CGFloat(masterImage.width) / 1024,
                                y: CGFloat(masterImage.height) / 1024))
guard let art = masterImage.cropping(to: plate) else { fatalError("crop failed") }

/// The macOS icon shape: a superellipse, squarer through the corners than a
/// plain rounded rect. Sampled finely enough to stay smooth at 1024pt.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let steps = 720
    for step in 0...steps {
        let theta = 2 * .pi * CGFloat(step) / CGFloat(steps)
        let c = cos(theta), s = sin(theta)
        let x = center.x + a * pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
        let y = center.y + b * pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func draw(size: CGFloat) -> Data {
    guard let context = CGContext(data: nil, width: Int(size), height: Int(size),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("no context") }

    context.scaleBy(x: size / 1024, y: size / 1024)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // macOS icons sit inside a rounded square with breathing room around it.
    let inset: CGFloat = 100
    let body = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let shape = squircle(in: body)

    context.saveGState()
    context.addPath(shape)
    context.clip()
    // A hair of overdraw so the mask's edge lands on artwork, never on nothing.
    context.draw(art, in: body.insetBy(dx: -2, dy: -2))
    context.restoreGState()

    // A whisper of a rim so the plate still has an edge on a dark desktop.
    context.addPath(shape)
    context.setStrokeColor(CGColor(srgbRed: 1, green: 0.95, blue: 1, alpha: 0.10))
    context.setLineWidth(3)
    context.strokePath()

    guard let image = context.makeImage() else { fatalError("no image") }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

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
