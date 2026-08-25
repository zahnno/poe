import SwiftUI

/// Three slow blurred orbs drifting behind the glass.
///
/// Everything is driven by `repeatForever` animations on transform properties,
/// so the whole effect is handed to the compositor — no per-frame CPU work,
/// no timer, nothing to spin the fans up while you type.
struct AuroraBackground: View {
    @State private var drift = false

    var body: some View {
        ZStack {
            Theme.void

            orb(Theme.accentDeep, size: 620)
                .offset(x: drift ? -180 : -260, y: drift ? -220 : -140)
                .opacity(0.55)

            orb(Theme.violet, size: 540)
                .offset(x: drift ? 260 : 180, y: drift ? -60 : -180)
                .opacity(0.45)

            orb(Theme.accent, size: 460)
                .offset(x: drift ? 40 : 160, y: drift ? 280 : 200)
                .opacity(0.30)

            orb(Theme.rose, size: 380)
                .offset(x: drift ? -280 : -180, y: drift ? 260 : 320)
                .opacity(0.22)

            // A faint grid, barely there — just enough to read as "instrument panel".
            GridVeil()
                .opacity(0.35)

            // Pull everything back toward black so text always wins.
            LinearGradient(
                colors: [Color.black.opacity(0.30), Color.black.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 22).repeatForever(autoreverses: true)) {
                drift.toggle()
            }
        }
    }

    private func orb(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color, color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
            .blur(radius: 60)
    }
}

/// A 44pt hairline grid that fades out toward the bottom of the window.
private struct GridVeil: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 44
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(.white.opacity(0.035)), lineWidth: 0.5)
        }
        .mask(
            LinearGradient(
                colors: [.white, .white.opacity(0.15), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}
