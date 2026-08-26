import AppKit
import SwiftUI

/// The whole visual language in one place: deep space background, glass panels,
/// and a cyan-to-violet accent that only ever appears on things you can act on.
enum Theme {
    static let void        = Color(red: 0.031, green: 0.035, blue: 0.055)
    static let panel       = Color.white.opacity(0.045)
    static let panelStroke = Color.white.opacity(0.075)
    static let hairline    = Color.white.opacity(0.055)
    /// Behind a fenced code block in the preview — what the glass panel there
    /// used to resolve to, without the live blur behind it.
    static let codePanel   = Color.white.opacity(0.075)

    static let ink         = Color(red: 0.898, green: 0.914, blue: 0.961)
    static let inkDim      = Color(red: 0.596, green: 0.627, blue: 0.714)
    static let inkFaint    = Color(red: 0.400, green: 0.435, blue: 0.529)

    static let accent      = Color(red: 0.373, green: 0.902, blue: 0.941)
    static let accentDeep  = Color(red: 0.482, green: 0.549, blue: 1.000)
    static let violet      = Color(red: 0.655, green: 0.545, blue: 0.980)
    static let rose        = Color(red: 0.957, green: 0.447, blue: 0.714)

    static let lantern     = Color(red: 1.000, green: 0.706, blue: 0.145)
    static let lanternDeep = Color(red: 0.980, green: 0.573, blue: 0.020)
    static let flame       = Color(red: 1.000, green: 0.965, blue: 0.812)
    static let frame       = Color(red: 0.624, green: 0.529, blue: 0.424)
    static let frameDeep   = Color(red: 0.365, green: 0.298, blue: 0.239)

    static let glow = LinearGradient(
        colors: [accent, accentDeep, violet],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let editorFont = NSFont(name: "SF Mono", size: 15)
        ?? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
}

/// A rounded glass card: translucent fill, hairline edge, no heavy shadows.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = 18
    var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(opacity)
            )
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.panelStroke, lineWidth: 1)
            )
    }
}

extension View {
    func glass(radius: CGFloat = 18, opacity: Double = 1) -> some View {
        modifier(GlassPanel(radius: radius, opacity: opacity))
    }

    /// Fades and lifts a view into place — used for note switches and mode changes.
    func softAppear() -> some View {
        transition(.opacity.combined(with: .offset(y: 6)))
    }
}

/// Built once. A `DateFormatter` costs about a tenth of a millisecond to
/// create, and the sidebar was building one per row per redraw.
private enum PoeFormatters {
    static let weekday = formatter("EEE")
    static let day = formatter("MMM d")
    static let dayAndYear = formatter("MMM d, yy")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter
    }
}

extension Date {
    /// "now", "12m", "3h", "Tue", "Mar 4" — short enough for a 260pt sidebar.
    var poeRelative: String {
        let seconds = Date().timeIntervalSince(self)
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        if seconds < 604_800 { return PoeFormatters.weekday.string(from: self) }
        let sameYear = Calendar.current.isDate(self, equalTo: Date(), toGranularity: .year)
        return (sameYear ? PoeFormatters.day : PoeFormatters.dayAndYear).string(from: self)
    }
}
