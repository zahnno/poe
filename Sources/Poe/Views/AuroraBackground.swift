import AppKit
import SwiftUI

/// Four slow orbs drifting behind the glass.
///
/// The softness is baked into the gradient stops rather than blurred: a
/// `.blur(radius: 60)` on a drifting 620pt circle is re-run every frame, for a
/// shape whose edge already fades to nothing.
///
/// Nothing that stays still sits inside the part that moves, either. The drift
/// is its own view, so the grid and the veil below it are drawn once and
/// composited from then on rather than being rebuilt sixty times a second in
/// order to look exactly as they already did.
struct AuroraBackground: View {
    var body: some View {
        ZStack {
            Theme.void

            Drift()
                .allowsHitTesting(false)

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
    }
}

/// The drift, handed to Core Animation.
///
/// It used to be a SwiftUI `repeatForever` on four offsets, which sounds free
/// and isn't: SwiftUI evaluates a running animation on the main thread on every
/// frame, forever, whether or not there is anything else to do. An idle Poe
/// spent most of its time interpolating four numbers nobody was watching.
/// Core Animation runs the same drift in the render server, so once the
/// animation is committed the app itself does no per-frame work at all.
///
/// It also pauses honestly. Stopping a SwiftUI animation means putting its
/// state back, which snaps the orbs to where they started; freezing a layer
/// tree leaves them exactly where they are. So the drift can stop whenever
/// nobody is looking — the window covered, or Poe simply not the app in front —
/// and nothing jumps when it picks up again.
private struct Drift: NSViewRepresentable {
    func makeNSView(context: Context) -> DriftView { DriftView() }
    func updateNSView(_ view: DriftView, context: Context) {}
}

final class DriftView: NSView {

    /// Where an orb sits at each end of its drift, in SwiftUI's terms: offsets
    /// from the centre of the window, y counting downward.
    private struct Orb {
        var color: Color
        var size: CGFloat
        var alpha: CGFloat
        var from: CGPoint
        var to: CGPoint
    }

    private static let orbs: [Orb] = [
        Orb(color: Theme.accentDeep, size: 700, alpha: 0.55,
            from: CGPoint(x: -260, y: -140), to: CGPoint(x: -180, y: -220)),
        Orb(color: Theme.violet, size: 620, alpha: 0.45,
            from: CGPoint(x: 180, y: -180), to: CGPoint(x: 260, y: -60)),
        Orb(color: Theme.accent, size: 540, alpha: 0.30,
            from: CGPoint(x: 160, y: 200), to: CGPoint(x: 40, y: 280)),
        Orb(color: Theme.rose, size: 460, alpha: 0.22,
            from: CGPoint(x: -180, y: 320), to: CGPoint(x: -280, y: 260))
    ]

    /// A gaussian-ish falloff, in stops. The tail matters more than the middle:
    /// it is what stops the circle reading as a circle. The opacity each orb
    /// used to carry as a separate modifier — a compositing pass of its own — is
    /// multiplied through these instead.
    private static let stops: [(location: CGFloat, opacity: CGFloat)] = [
        (0.00, 1.00), (0.26, 0.78), (0.46, 0.44), (0.64, 0.20), (0.80, 0.07), (1.00, 0.00)
    ]

    private static let period: CFTimeInterval = 22

    private var orbLayers: [CAGradientLayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for name in [
            NSApplication.didChangeOcclusionStateNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(watchingChanged), name: name, object: nil
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Where the orbs are *right now*, as the render server has them — which is
    /// not where the layer's own `position` says, once an animation is driving
    /// it. The self test reads this to tell a drift that is running from one
    /// that has stopped; a screenshot cannot, because `cacheDisplay` draws the
    /// model tree and never sees a Core Animation frame at all.
    var driftPhase: [CGPoint] {
        orbLayers.map { $0.presentation()?.position ?? $0.position }
    }

    var isDrifting: Bool { (layer?.speed ?? 0) != 0 }

    /// The background never wants the mouse; it sits under the whole window.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        watchingChanged()
    }

    override func layout() {
        super.layout()
        rebuild()
    }

    // MARK: - The orbs

    private func rebuild() {
        guard let host = layer, bounds.width > 0, bounds.height > 0 else { return }

        if orbLayers.count != Self.orbs.count {
            orbLayers.forEach { $0.removeFromSuperlayer() }
            orbLayers = Self.orbs.map { orb in
                let gradient = CAGradientLayer()
                gradient.type = .radial
                gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
                // For a radial gradient this corner is the extent of the ellipse:
                // half the layer either way, which is the orb's own radius.
                gradient.endPoint = CGPoint(x: 1, y: 1)
                gradient.locations = Self.stops.map { NSNumber(value: Double($0.location)) }
                gradient.colors = Self.stops.map {
                    NSColor(orb.color).withAlphaComponent($0.opacity * orb.alpha).cgColor
                }
                gradient.contentsScale = host.contentsScale
                gradient.needsDisplayOnBoundsChange = false
                host.addSublayer(gradient)
                return gradient
            }
        }

        // Laying out mustn't animate, and mustn't be seen to restart the drift.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, orb) in Self.orbs.enumerated() {
            let gradient = orbLayers[index]
            gradient.bounds = CGRect(x: 0, y: 0, width: orb.size, height: orb.size)
            gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
            // Only ever added once. The drift is written as an offset from
            // wherever the orb sits rather than as two absolute points, so
            // resizing the window moves the orb without the animation noticing
            // — re-adding it here would restart its phase, and every layout
            // pass would jerk the background back to where it began.
            if gradient.animation(forKey: Self.driftKey) == nil {
                gradient.add(Self.drift(for: orb), forKey: Self.driftKey)
            }
        }
        CATransaction.commit()
    }

    private static let driftKey = "drift"

    private static func drift(for orb: Orb) -> CABasicAnimation {
        let drift = CABasicAnimation(keyPath: "position")
        // Added to the orb's position rather than replacing it — see above.
        drift.isAdditive = true
        // AppKit counts y upward and SwiftUI counts it down, so the offsets the
        // design was written in are negated on the way through.
        drift.fromValue = NSValue(point: CGPoint(x: orb.from.x, y: -orb.from.y))
        drift.toValue = NSValue(point: CGPoint(x: orb.to.x, y: -orb.to.y))
        drift.duration = period
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return drift
    }

    // MARK: - Only while someone is looking

    /// Covered, minimised, another app full-screen over the top — or simply not
    /// the app in front. A drift this slow is imperceptible frame to frame, so
    /// nobody sees it stop, and stopping it is the difference between a notepad
    /// that idles at nothing and one that idles at a twentieth of a core.
    @objc private func watchingChanged() {
        let watched = NSApp.occlusionState.contains(.visible)
            && NSApp.isActive
            && window?.isVisible == true
        if watched { resume() } else { pause() }
    }

    private func pause() {
        guard let host = layer, host.speed != 0 else { return }
        host.timeOffset = host.convertTime(CACurrentMediaTime(), from: nil)
        host.speed = 0
    }

    private func resume() {
        guard let host = layer, host.speed == 0 else { return }
        let frozen = host.timeOffset
        host.speed = 1
        host.timeOffset = 0
        host.beginTime = 0
        host.beginTime = host.convertTime(CACurrentMediaTime(), from: nil) - frozen
    }
}

/// A 44pt hairline grid that fades out toward the bottom of the window.
///
/// The fade used to be a `.mask()`, which is an offscreen render of the whole
/// window: the grid drawn into one buffer, a gradient into another, the two
/// multiplied and composited back. This paints the same picture directly — the
/// verticals take the gradient as their stroke, and each horizontal is drawn at
/// the one opacity the mask would have given it.
private struct GridVeil: View {
    /// White at the top, nearly gone by halfway, gone at the bottom — the stops
    /// the mask gradient used, and the curve `fade(at:)` reads back off them.
    private static let stops: [(location: CGFloat, opacity: CGFloat)] = [
        (0.0, 1.0), (0.5, 0.15), (1.0, 0.0)
    ]

    private static func fade(at fraction: CGFloat) -> CGFloat {
        let clamped = min(max(fraction, 0), 1)
        for index in 1..<stops.count where clamped <= stops[index].location {
            let start = stops[index - 1], end = stops[index]
            let span = end.location - start.location
            let position = span > 0 ? (clamped - start.location) / span : 0
            return start.opacity + (end.opacity - start.opacity) * position
        }
        return stops[stops.count - 1].opacity
    }

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 44
            let ink: CGFloat = 0.035

            var verticals = Path()
            var x: CGFloat = 0
            while x <= size.width {
                verticals.move(to: CGPoint(x: x, y: 0))
                verticals.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            context.stroke(
                verticals,
                with: .linearGradient(
                    Gradient(stops: Self.stops.map {
                        .init(color: .white.opacity(ink * $0.opacity), location: $0.location)
                    }),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                ),
                lineWidth: 0.5
            )

            var y: CGFloat = 0
            while y <= size.height {
                let opacity = ink * Self.fade(at: size.height > 0 ? y / size.height : 0)
                // The lowest of them would land on nothing anyway.
                if opacity > 0.0005 {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(.white.opacity(opacity)), lineWidth: 0.5)
                }
                y += step
            }
        }
    }
}
