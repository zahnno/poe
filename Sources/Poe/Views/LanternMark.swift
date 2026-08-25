import SwiftUI

/// Poe's mark: a small lantern, lit. Drawn to match the app icon — bronze frame,
/// wire-guarded glass, a flame at the heart — so the app and the Dock read as
/// the same object.
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
            func bar(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ h: CGFloat) -> Path {
                Path(roundedRect: rect(x, y, width, h), cornerRadius: min(width, h) * scale * 0.4)
            }

            let bronze = Theme.frame
            let bronzeDeep = Theme.frameDeep

            // --- the glass, so the frame can sit on top of it ----------------
            var glass = Path()
            glass.move(to: point(37, 55))
            glass.addCurve(to: point(37, 95), control1: point(30, 68), control2: point(30, 82))
            glass.addLine(to: point(63, 95))
            glass.addCurve(to: point(63, 55), control1: point(70, 82), control2: point(70, 68))
            glass.closeSubpath()

            context.fill(glass, with: .radialGradient(
                Gradient(colors: [Theme.flame, Theme.lantern, Theme.lanternDeep.opacity(0.85)]),
                center: point(50, 82), startRadius: 0, endRadius: 26 * scale
            ))

            // The flame at the heart of it.
            var flame = Path()
            flame.move(to: point(50, 72))
            flame.addCurve(to: point(50, 89), control1: point(57, 81), control2: point(55, 89))
            flame.addCurve(to: point(50, 72), control1: point(45, 89), control2: point(43, 81))
            flame.closeSubpath()
            context.fill(flame, with: .linearGradient(
                Gradient(colors: [Theme.lanternDeep, Theme.lantern, .white]),
                startPoint: point(50, 72), endPoint: point(50, 89)
            ))

            // --- the wire guard crossing the panes ---------------------------
            context.drawLayer { layer in
                layer.clip(to: glass)
                var wires = Path()
                wires.move(to: point(35, 63)); wires.addLine(to: point(65, 87))
                wires.move(to: point(65, 63)); wires.addLine(to: point(35, 87))
                wires.move(to: point(34, 89)); wires.addLine(to: point(66, 89))
                layer.stroke(wires, with: .color(bronzeDeep), lineWidth: 2.6 * scale)
            }

            // --- bail arms, bowed around the glass ---------------------------
            for side in [CGFloat(-1), 1] {
                var rail = Path()
                rail.move(to: point(50 + side * 22, 31))
                rail.addCurve(to: point(50 + side * 22, 103),
                              control1: point(50 + side * 31, 52),
                              control2: point(50 + side * 31, 84))
                context.stroke(rail, with: .color(bronzeDeep), lineWidth: 3.2 * scale)

                // The little pins where the arm meets the collar.
                let pin = side < 0 ? CGFloat(19) : 72
                context.fill(bar(pin, 30, 9, 3), with: .color(bronze))
            }

            // --- lid, collar and burner --------------------------------------
            var handle = Path()
            handle.addArc(center: point(50, 13), radius: 7 * scale,
                          startAngle: .degrees(175), endAngle: .degrees(5), clockwise: false)
            context.stroke(handle, with: .color(bronze), lineWidth: 3 * scale)

            var lid = Path()
            lid.move(to: point(35, 19))
            lid.addLine(to: point(65, 19))
            lid.addLine(to: point(71, 26))
            lid.addLine(to: point(29, 26))
            lid.closeSubpath()
            context.fill(lid, with: .color(bronze))

            context.fill(bar(37, 26, 26, 6), with: .color(bronzeDeep))
            context.fill(bar(35, 32, 30, 6), with: .color(bronze))
            context.fill(bar(39, 38, 22, 9), with: .color(bronzeDeep))

            // Vent holes along the burner.
            for x in [CGFloat(43), 50, 57] {
                context.fill(Path(ellipseIn: rect(x - 1.4, 41.5, 2.8, 2.8)),
                             with: .color(Theme.void.opacity(0.75)))
            }

            // The skirt that flares down onto the glass.
            var skirt = Path()
            skirt.move(to: point(37, 47))
            skirt.addLine(to: point(63, 47))
            skirt.addLine(to: point(69, 56))
            skirt.addLine(to: point(31, 56))
            skirt.closeSubpath()
            context.fill(skirt, with: .linearGradient(
                Gradient(colors: [bronze, bronzeDeep]),
                startPoint: point(31, 47), endPoint: point(69, 56)
            ))

            // --- fount, foot and the wick knob -------------------------------
            context.fill(bar(33, 93, 34, 7), with: .color(bronze))

            var fount = Path()
            fount.move(to: point(34, 100))
            fount.addLine(to: point(66, 100))
            fount.addLine(to: point(63, 114))
            fount.addLine(to: point(37, 114))
            fount.closeSubpath()
            context.fill(fount, with: .linearGradient(
                Gradient(colors: [bronze, bronzeDeep]),
                startPoint: point(34, 100), endPoint: point(66, 114)
            ))
            context.fill(bar(45, 96, 10, 7), with: .color(bronzeDeep))

            var foot = Path()
            foot.move(to: point(35, 114))
            foot.addLine(to: point(65, 114))
            foot.addLine(to: point(68, 128))
            foot.addLine(to: point(32, 128))
            foot.closeSubpath()
            context.fill(foot, with: .color(bronze))
            context.fill(bar(30, 128, 40, 5), with: .color(bronzeDeep))
        }
        .frame(width: height * design.width / design.height, height: height)
        .shadow(color: glow ? Theme.lantern.opacity(0.75) : .clear, radius: height * 0.32)
    }
}
