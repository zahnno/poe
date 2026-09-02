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
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        ZStack {
            Theme.void
                .animation(.easeInOut(duration: 0.25), value: themeManager.currentTheme.id)

            Drift(theme: themeManager.currentTheme)
                .allowsHitTesting(false)

            // A faint grid, barely there — just enough to read as "instrument panel".
            GridVeil(isLight: themeManager.currentTheme.isLight)
                .opacity(themeManager.currentTheme.isLight ? 0.18 : 0.35)

            // Pull everything back toward dark or light so text always wins.
            LinearGradient(
                colors: themeManager.currentTheme.isLight
                    ? [Color.white.opacity(0.12), Color.white.opacity(0.35)]
                    : [Color.black.opacity(0.30), Color.black.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

/// The drift, handed to Core Animation.
private struct Drift: NSViewRepresentable {
    var theme: ThemeDefinition

    func makeNSView(context: Context) -> DriftView {
        let view = DriftView()
        view.configure(with: theme)
        return view
    }

    func updateNSView(_ view: DriftView, context: Context) {
        view.configure(with: theme)
    }
}

final class DriftView: NSView {
    private var theme: ThemeDefinition = Theme.current

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

    func configure(with newTheme: ThemeDefinition) {
        self.theme = newTheme
        guard layer != nil, bounds.width > 0, bounds.height > 0 else { return }

        if orbLayers.count == newTheme.orbs.count && !orbLayers.isEmpty {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.35)
            for (index, orb) in newTheme.orbs.enumerated() {
                orbLayers[index].colors = Self.stops.map {
                    NSColor(orb.color).withAlphaComponent($0.opacity * orb.alpha).cgColor
                }
            }
            CATransaction.commit()
        } else {
            rebuild()
        }
    }

    private func rebuild() {
        guard let host = layer, bounds.width > 0, bounds.height > 0 else { return }
        let orbs = theme.orbs

        if orbLayers.count != orbs.count {
            orbLayers.forEach { $0.removeFromSuperlayer() }
            orbLayers = orbs.map { orb in
                let gradient = CAGradientLayer()
                gradient.type = .radial
                gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
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
        for (index, orb) in orbs.enumerated() {
            let gradient = orbLayers[index]
            gradient.bounds = CGRect(x: 0, y: 0, width: orb.size, height: orb.size)
            gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
            if gradient.animation(forKey: Self.driftKey) == nil {
                gradient.add(Self.drift(for: orb), forKey: Self.driftKey)
            }
        }
        CATransaction.commit()
    }

    private static let driftKey = "drift"

    private static func drift(for orb: ThemeOrb) -> CABasicAnimation {
        let drift = CABasicAnimation(keyPath: "position")
        drift.isAdditive = true
        drift.fromValue = NSValue(point: CGPoint(x: orb.from.x, y: -orb.from.y))
        drift.toValue = NSValue(point: CGPoint(x: orb.to.x, y: -orb.to.y))
        drift.duration = period
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return drift
    }

    // MARK: - Only while someone is looking

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
private struct GridVeil: View {
    var isLight: Bool = false

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
            let ink: CGFloat = isLight ? 0.05 : 0.035
            let lineColor: Color = isLight ? .black : .white

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
                        .init(color: lineColor.opacity(ink * $0.opacity), location: $0.location)
                    }),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                ),
                lineWidth: 0.5
            )

            var y: CGFloat = 0
            while y <= size.height {
                let opacity = ink * Self.fade(at: size.height > 0 ? y / size.height : 0)
                if opacity > 0.0005 {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(lineColor.opacity(opacity)), lineWidth: 0.5)
                }
                y += step
            }
        }
    }
}
