import SwiftUI

/// Poe's mark: a small lantern, lit. Drawn to match the app icon so the app and
/// the Dock read as the same object.
struct LanternMark: View {
    var height: CGFloat = 22
    var glow: Bool = true

    private let design = CGSize(width: 100, height: 140)

    var body: some View {
        Canvas { context, size in
            let scale = size.height / design.height
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scale, y: y * scale)
            }
            func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: x * scale, y: y * scale, width: width * scale, height: h * scale)
            }

            // Handle.
            var handle = Path()
            handle.addArc(center: point(50, 26), radius: 16 * scale,
                          startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            context.stroke(handle, with: .color(Theme.frame), lineWidth: 6 * scale)

            // Cap.
            var cap = Path()
            cap.move(to: point(36, 22))
            cap.addLine(to: point(64, 22))
            cap.addLine(to: point(78, 36))
            cap.addLine(to: point(22, 36))
            cap.closeSubpath()
            context.fill(cap, with: .color(Theme.frame))

            // Glass.
            var glass = Path()
            glass.move(to: point(29, 42))
            glass.addCurve(to: point(29, 102), control1: point(15, 60), control2: point(15, 84))
            glass.addLine(to: point(71, 102))
            glass.addCurve(to: point(71, 42), control1: point(85, 84), control2: point(85, 60))
            glass.closeSubpath()
            context.fill(glass, with: .linearGradient(
                Gradient(colors: [Theme.flame, Theme.lantern, Theme.lanternDeep]),
                startPoint: point(29, 42), endPoint: point(71, 102)
            ))

            // Pane bars, clipped to the glass.
            context.drawLayer { layer in
                layer.clip(to: glass)
                layer.fill(Path(rect(45, 40, 3.5, 64)), with: .color(Theme.frame.opacity(0.55)))
                layer.fill(Path(rect(53, 40, 3.5, 64)), with: .color(Theme.frame.opacity(0.55)))
            }

            // Rings, base, foot.
            context.fill(Path(rect(19, 35, 62, 7)), with: .color(Theme.frame))
            context.fill(Path(rect(23, 99, 54, 7)), with: .color(Theme.frame))

            var base = Path()
            base.move(to: point(27, 106))
            base.addLine(to: point(73, 106))
            base.addLine(to: point(64, 122))
            base.addLine(to: point(36, 122))
            base.closeSubpath()
            context.fill(base, with: .color(Theme.frame))
            context.fill(Path(rect(43, 122, 14, 6)), with: .color(Theme.frame))
        }
        .frame(width: height * design.width / design.height, height: height)
        .shadow(color: glow ? Theme.lantern.opacity(0.75) : .clear, radius: height * 0.32)
    }
}
