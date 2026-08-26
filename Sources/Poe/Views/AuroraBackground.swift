import AppKit
import SwiftUI

/// Four slow orbs drifting behind the glass.
///
/// The drift is a `repeatForever` animation on nothing but offsets, so what it
/// costs per frame is what those offsets have to move. That used to be four
/// full-screen gaussian blurs: `.blur(radius: 60)` on a drifting 620pt circle
/// is re-run every frame, for a shape whose edge already fades to nothing. The
/// softness is baked into the gradient stops instead, which the compositor
/// draws once and then simply slides about.
///
/// The animation itself still has to be evaluated every frame for as long as it
/// runs, so it doesn't run while the app has nothing on screen.
struct AuroraBackground: View {
    @State private var drift = false

    var body: some View {
        ZStack {
            Theme.void

            orb(Theme.accentDeep, size: 700)
                .offset(x: drift ? -180 : -260, y: drift ? -220 : -140)
                .opacity(0.55)

            orb(Theme.violet, size: 620)
                .offset(x: drift ? 260 : 180, y: drift ? -60 : -180)
                .opacity(0.45)

            orb(Theme.accent, size: 540)
                .offset(x: drift ? 40 : 160, y: drift ? 280 : 200)
                .opacity(0.30)

            orb(Theme.rose, size: 460)
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
        // Deliberately *not* a `.drawingGroup()`: the drift lives inside this
        // stack, so flattening it would force an offscreen render of the whole
        // background every frame instead of letting the compositor slide four
        // gradient layers around.
        .onAppear(perform: start)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeOcclusionStateNotification
        )) { _ in
            // A `repeatForever` animation is evaluated every frame for as long
            // as it runs, whether or not there is anyone to see it. When every
            // window is hidden — minimised, covered, another app full-screen
            // over the top — there is nothing to draw, so stop drawing it.
            if NSApp.occlusionState.contains(.visible) { start() } else { stop() }
        }
    }

    private func start() {
        guard !drift else { return }
        withAnimation(.easeInOut(duration: 22).repeatForever(autoreverses: true)) {
            drift = true
        }
    }

    private func stop() {
        withAnimation(.linear(duration: 0)) { drift = false }
    }

    /// A gaussian-ish falloff, in stops. The tail matters more than the middle:
    /// it is what stops the circle reading as a circle.
    private func orb(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: color, location: 0.00),
                        .init(color: color.opacity(0.78), location: 0.26),
                        .init(color: color.opacity(0.44), location: 0.46),
                        .init(color: color.opacity(0.20), location: 0.64),
                        .init(color: color.opacity(0.07), location: 0.80),
                        .init(color: color.opacity(0.00), location: 1.00)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
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
