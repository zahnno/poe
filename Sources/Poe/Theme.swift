import AppKit
import SwiftUI

// MARK: - Color & NSColor Hex Initializers

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, opacity: alpha)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
}

// MARK: - Theme Category

enum ThemeCategory: String, CaseIterable, Identifiable {
    case celestial = "Celestial & Deep Space"
    case nature = "Nature & Earth"
    case cyber = "Cyberpunk & Neon"
    case literary = "Literary & Scholar"
    case developer = "Code & Developer"
    case mood = "Atmospheric & Mood"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .celestial: return "sparkles"
        case .nature: return "leaf.fill"
        case .cyber: return "bolt.fill"
        case .literary: return "books.vertical.fill"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .mood: return "sunset.fill"
        }
    }
}

// MARK: - Theme Orb

struct ThemeOrb: Equatable {
    var color: Color
    var size: CGFloat
    var alpha: CGFloat
    var from: CGPoint
    var to: CGPoint
}

// MARK: - Theme Definition

struct ThemeDefinition: Identifiable, Equatable {
    let id: String
    let name: String
    let category: ThemeCategory
    let isLight: Bool

    let void: Color
    let panel: Color
    let panelStroke: Color
    let hairline: Color
    let codePanel: Color

    let ink: Color
    let inkDim: Color
    let inkFaint: Color

    let accent: Color
    let accentDeep: Color
    let violet: Color
    let rose: Color

    let lantern: Color
    let lanternDeep: Color
    let flame: Color
    let frame: Color
    let frameDeep: Color

    let orbs: [ThemeOrb]

    static func == (lhs: ThemeDefinition, rhs: ThemeDefinition) -> Bool {
        lhs.id == rhs.id
    }

    init(
        id: String,
        name: String,
        category: ThemeCategory,
        isLight: Bool = false,
        voidHex: UInt32,
        panelHex: UInt32? = nil,
        panelAlpha: Double? = nil,
        panelStrokeHex: UInt32? = nil,
        panelStrokeAlpha: Double? = nil,
        hairlineHex: UInt32? = nil,
        hairlineAlpha: Double? = nil,
        codePanelHex: UInt32? = nil,
        codePanelAlpha: Double? = nil,
        inkHex: UInt32,
        inkDimHex: UInt32,
        inkFaintHex: UInt32,
        accentHex: UInt32,
        accentDeepHex: UInt32,
        violetHex: UInt32,
        roseHex: UInt32,
        lanternHex: UInt32? = nil,
        lanternDeepHex: UInt32? = nil,
        flameHex: UInt32? = nil,
        frameHex: UInt32? = nil,
        frameDeepHex: UInt32? = nil,
        customOrbs: [ThemeOrb]? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.isLight = isLight

        self.void = Color(hex: voidHex)

        if isLight {
            self.panel = Color(hex: panelHex ?? 0x000000, alpha: panelAlpha ?? 0.040)
            self.panelStroke = Color(hex: panelStrokeHex ?? 0x000000, alpha: panelStrokeAlpha ?? 0.080)
            self.hairline = Color(hex: hairlineHex ?? 0x000000, alpha: hairlineAlpha ?? 0.060)
            self.codePanel = Color(hex: codePanelHex ?? 0x000000, alpha: codePanelAlpha ?? 0.050)
        } else {
            self.panel = Color(hex: panelHex ?? 0xFFFFFF, alpha: panelAlpha ?? 0.045)
            self.panelStroke = Color(hex: panelStrokeHex ?? 0xFFFFFF, alpha: panelStrokeAlpha ?? 0.075)
            self.hairline = Color(hex: hairlineHex ?? 0xFFFFFF, alpha: hairlineAlpha ?? 0.055)
            self.codePanel = Color(hex: codePanelHex ?? 0xFFFFFF, alpha: codePanelAlpha ?? 0.075)
        }

        self.ink = Color(hex: inkHex)
        self.inkDim = Color(hex: inkDimHex)
        self.inkFaint = Color(hex: inkFaintHex)

        let acc = Color(hex: accentHex)
        let accDeep = Color(hex: accentDeepHex)
        let vio = Color(hex: violetHex)
        let ros = Color(hex: roseHex)

        self.accent = acc
        self.accentDeep = accDeep
        self.violet = vio
        self.rose = ros

        self.lantern = Color(hex: lanternHex ?? 0xFFB425)
        self.lanternDeep = Color(hex: lanternDeepHex ?? 0xFA9205)
        self.flame = Color(hex: flameHex ?? 0xFFF6CF)
        self.frame = Color(hex: frameHex ?? 0x9F876C)
        self.frameDeep = Color(hex: frameDeepHex ?? 0x5D4C3D)

        if let customOrbs {
            self.orbs = customOrbs
        } else {
            let alphaScale: CGFloat = isLight ? 0.35 : 1.0
            self.orbs = [
                ThemeOrb(color: accDeep, size: 700, alpha: 0.55 * alphaScale,
                         from: CGPoint(x: -260, y: -140), to: CGPoint(x: -180, y: -220)),
                ThemeOrb(color: vio, size: 620, alpha: 0.45 * alphaScale,
                         from: CGPoint(x: 180, y: -180), to: CGPoint(x: 260, y: -60)),
                ThemeOrb(color: acc, size: 540, alpha: 0.30 * alphaScale,
                         from: CGPoint(x: 160, y: 200), to: CGPoint(x: 40, y: 280)),
                ThemeOrb(color: ros, size: 460, alpha: 0.22 * alphaScale,
                         from: CGPoint(x: -180, y: 320), to: CGPoint(x: -280, y: 260))
            ]
        }
    }
}

// MARK: - All 40 Themes Catalog

extension Theme {
    static let allThemes: [ThemeDefinition] = [

        // ==========================================
        // 1. CELESTIAL & DEEP SPACE (5 themes)
        // ==========================================

        ThemeDefinition(
            id: "abyss",
            name: "Abyss (Classic Poe)",
            category: .celestial,
            voidHex: 0x08090E,
            inkHex: 0xE5E9F5,
            inkDimHex: 0x98A0B6,
            inkFaintHex: 0x666F87,
            accentHex: 0x5FE6F0,
            accentDeepHex: 0x7B8CFF,
            violetHex: 0xA78BFA,
            roseHex: 0xF472B6,
            lanternHex: 0xFFB425,
            lanternDeepHex: 0xFA9205,
            flameHex: 0xFFF6CF,
            frameHex: 0x9F876C,
            frameDeepHex: 0x5D4C3D
        ),

        ThemeDefinition(
            id: "nebula",
            name: "Nebula",
            category: .celestial,
            voidHex: 0x0B0817,
            inkHex: 0xF1EBFB,
            inkDimHex: 0xA493C4,
            inkFaintHex: 0x675782,
            accentHex: 0xE879F9,
            accentDeepHex: 0x9333EA,
            violetHex: 0xC084FC,
            roseHex: 0xFB7185,
            lanternHex: 0xF472B6,
            lanternDeepHex: 0xC026D3,
            flameHex: 0xFDF4FF,
            frameHex: 0x865D8C,
            frameDeepHex: 0x4A2E50
        ),

        ThemeDefinition(
            id: "supernova",
            name: "Supernova",
            category: .celestial,
            voidHex: 0x0F0A06,
            inkHex: 0xFEF3C7,
            inkDimHex: 0xD97706,
            inkFaintHex: 0x78350F,
            accentHex: 0xF59E0B,
            accentDeepHex: 0xD97706,
            violetHex: 0xF97316,
            roseHex: 0xEF4444,
            lanternHex: 0xFBBF24,
            lanternDeepHex: 0xD97706,
            flameHex: 0xFEF9C3,
            frameHex: 0xA16207,
            frameDeepHex: 0x543105
        ),

        ThemeDefinition(
            id: "andromeda",
            name: "Andromeda",
            category: .celestial,
            voidHex: 0x070B16,
            inkHex: 0xE0E7FF,
            inkDimHex: 0x818CF8,
            inkFaintHex: 0x4338CA,
            accentHex: 0x2DD4BF,
            accentDeepHex: 0x3B82F6,
            violetHex: 0x818CF8,
            roseHex: 0xF43F5E,
            lanternHex: 0x38BDF8,
            lanternDeepHex: 0x0284C7,
            flameHex: 0xE0F2FE,
            frameHex: 0x475569,
            frameDeepHex: 0x1E293B
        ),

        ThemeDefinition(
            id: "event_horizon",
            name: "Event Horizon",
            category: .celestial,
            voidHex: 0x050508,
            inkHex: 0xF8FAFC,
            inkDimHex: 0x94A3B8,
            inkFaintHex: 0x475569,
            accentHex: 0x8B5CF6,
            accentDeepHex: 0x6D28D9,
            violetHex: 0xA78BFA,
            roseHex: 0xF43F5E,
            lanternHex: 0xA855F7,
            lanternDeepHex: 0x7E22CE,
            flameHex: 0xFAF5FF,
            frameHex: 0x64748B,
            frameDeepHex: 0x334155
        ),

        // ==========================================
        // 2. NATURE & EARTH (7 themes)
        // ==========================================

        ThemeDefinition(
            id: "boreal",
            name: "Boreal Aurora",
            category: .nature,
            voidHex: 0x040F0A,
            inkHex: 0xECFDF5,
            inkDimHex: 0x6EE7B7,
            inkFaintHex: 0x047857,
            accentHex: 0x10B981,
            accentDeepHex: 0x059669,
            violetHex: 0x34D399,
            roseHex: 0xF87171,
            lanternHex: 0x34D399,
            lanternDeepHex: 0x059669,
            flameHex: 0xD1FAE5,
            frameHex: 0x065F46,
            frameDeepHex: 0x022C22
        ),

        ThemeDefinition(
            id: "moss_stone",
            name: "Moss & Stone",
            category: .nature,
            voidHex: 0x0C100D,
            inkHex: 0xE2E8F0,
            inkDimHex: 0x94A3B8,
            inkFaintHex: 0x526058,
            accentHex: 0x84CC16,
            accentDeepHex: 0x65A30D,
            violetHex: 0x4ADE80,
            roseHex: 0xE11D48,
            lanternHex: 0xA3E635,
            lanternDeepHex: 0x65A30D,
            flameHex: 0xF7FEE7,
            frameHex: 0x71717A,
            frameDeepHex: 0x3F3F46
        ),

        ThemeDefinition(
            id: "volcanic",
            name: "Volcanic",
            category: .nature,
            voidHex: 0x120A0A,
            inkHex: 0xFEE2E2,
            inkDimHex: 0xF87171,
            inkFaintHex: 0x7F1D1D,
            accentHex: 0xEF4444,
            accentDeepHex: 0xB91C1C,
            violetHex: 0xF97316,
            roseHex: 0xF43F5E,
            lanternHex: 0xF97316,
            lanternDeepHex: 0xC2410C,
            flameHex: 0xFEF08A,
            frameHex: 0x78350F,
            frameDeepHex: 0x451A03
        ),

        ThemeDefinition(
            id: "desert_dunes",
            name: "Desert Dunes",
            category: .nature,
            voidHex: 0x140E0A,
            inkHex: 0xFEF3C7,
            inkDimHex: 0xFBBF24,
            inkFaintHex: 0x78350F,
            accentHex: 0xF59E0B,
            accentDeepHex: 0xD97706,
            violetHex: 0xFB7185,
            roseHex: 0xE11D48,
            lanternHex: 0xF59E0B,
            lanternDeepHex: 0xB45309,
            flameHex: 0xFEF3C7,
            frameHex: 0x92400E,
            frameDeepHex: 0x451A03
        ),

        ThemeDefinition(
            id: "deep_ocean",
            name: "Deep Ocean",
            category: .nature,
            voidHex: 0x030A14,
            inkHex: 0xE0F2FE,
            inkDimHex: 0x7DD3FC,
            inkFaintHex: 0x075985,
            accentHex: 0x06B6D4,
            accentDeepHex: 0x0284C7,
            violetHex: 0x38BDF8,
            roseHex: 0xFB7185,
            lanternHex: 0x22D3EE,
            lanternDeepHex: 0x0891B2,
            flameHex: 0xECFEFF,
            frameHex: 0x0E7490,
            frameDeepHex: 0x155E75
        ),

        ThemeDefinition(
            id: "rainforest",
            name: "Rainforest Canopy",
            category: .nature,
            voidHex: 0x061208,
            inkHex: 0xDCFCE7,
            inkDimHex: 0x86EFAC,
            inkFaintHex: 0x166534,
            accentHex: 0x22C55E,
            accentDeepHex: 0x15803D,
            violetHex: 0xA855F7,
            roseHex: 0xF43F5E,
            lanternHex: 0xEAB308,
            lanternDeepHex: 0xA16207,
            flameHex: 0xFEF9C3,
            frameHex: 0x365314,
            frameDeepHex: 0x1A2E05
        ),

        ThemeDefinition(
            id: "glacier",
            name: "Glacier",
            category: .nature,
            voidHex: 0x081018,
            inkHex: 0xF0F9FF,
            inkDimHex: 0xBAE6FD,
            inkFaintHex: 0x38BDF8,
            accentHex: 0x38BDF8,
            accentDeepHex: 0x0284C7,
            violetHex: 0x818CF8,
            roseHex: 0xF472B6,
            lanternHex: 0x7DD3FC,
            lanternDeepHex: 0x0284C7,
            flameHex: 0xF0FDF4,
            frameHex: 0x475569,
            frameDeepHex: 0x1E293B
        ),

        // ==========================================
        // 3. CYBERPUNK & NEON (5 themes)
        // ==========================================

        ThemeDefinition(
            id: "cyberpunk",
            name: "Cyberpunk 2077",
            category: .cyber,
            voidHex: 0x0A0910,
            inkHex: 0xFFFBEB,
            inkDimHex: 0xFDE047,
            inkFaintHex: 0x854D0E,
            accentHex: 0xFACC15,
            accentDeepHex: 0xCA8A04,
            violetHex: 0xF43F5E,
            roseHex: 0xFB7185,
            lanternHex: 0xFACC15,
            lanternDeepHex: 0xE11D48,
            flameHex: 0xFEF08A,
            frameHex: 0xE11D48,
            frameDeepHex: 0x881337
        ),

        ThemeDefinition(
            id: "synthwave",
            name: "Synthwave '84",
            category: .cyber,
            voidHex: 0x12081E,
            inkHex: 0xFDF2F8,
            inkDimHex: 0xF472B6,
            inkFaintHex: 0x831843,
            accentHex: 0xF43F5E,
            accentDeepHex: 0xA21CAF,
            violetHex: 0x00F0FF,
            roseHex: 0xFB7185,
            lanternHex: 0xF43F5E,
            lanternDeepHex: 0xC026D3,
            flameHex: 0xFFE4E6,
            frameHex: 0x9333EA,
            frameDeepHex: 0x581C87
        ),

        ThemeDefinition(
            id: "matrix",
            name: "Matrix Terminal",
            category: .cyber,
            voidHex: 0x030A04,
            inkHex: 0xDCFCE7,
            inkDimHex: 0x4ADE80,
            inkFaintHex: 0x14532D,
            accentHex: 0x22C55E,
            accentDeepHex: 0x15803D,
            violetHex: 0x10B981,
            roseHex: 0xEF4444,
            lanternHex: 0x4ADE80,
            lanternDeepHex: 0x16A34A,
            flameHex: 0xF0FDF4,
            frameHex: 0x166534,
            frameDeepHex: 0x052E16
        ),

        ThemeDefinition(
            id: "neo_tokyo",
            name: "Neo Tokyo",
            category: .cyber,
            voidHex: 0x0A0A14,
            inkHex: 0xF8FAFC,
            inkDimHex: 0xC084FC,
            inkFaintHex: 0x581C87,
            accentHex: 0xF472B6,
            accentDeepHex: 0x8B5CF6,
            violetHex: 0x38BDF8,
            roseHex: 0xFB7185,
            lanternHex: 0xF472B6,
            lanternDeepHex: 0x9333EA,
            flameHex: 0xFDF2F8,
            frameHex: 0x6D28D9,
            frameDeepHex: 0x3B0764
        ),

        ThemeDefinition(
            id: "laser_grid",
            name: "Laser Grid",
            category: .cyber,
            voidHex: 0x050814,
            inkHex: 0xF8FAFC,
            inkDimHex: 0x93C5FD,
            inkFaintHex: 0x1E3A8A,
            accentHex: 0xFF0055,
            accentDeepHex: 0x0088FF,
            violetHex: 0x00F0FF,
            roseHex: 0xFF0055,
            lanternHex: 0xFF0055,
            lanternDeepHex: 0x990033,
            flameHex: 0xFFFFFF,
            frameHex: 0x0088FF,
            frameDeepHex: 0x003366
        ),

        // ==========================================
        // 4. LITERARY, VINTAGE & SCHOLAR (6 themes)
        // ==========================================

        ThemeDefinition(
            id: "parchment",
            name: "Parchment & Gall (Light)",
            category: .literary,
            isLight: true,
            voidHex: 0xF8F4EB,
            inkHex: 0x292524,
            inkDimHex: 0x57534E,
            inkFaintHex: 0xA8A29E,
            accentHex: 0xB45309,
            accentDeepHex: 0x991B1B,
            violetHex: 0x7C2D12,
            roseHex: 0xDC2626,
            lanternHex: 0xD97706,
            lanternDeepHex: 0x92400E,
            flameHex: 0xFFFBEB,
            frameHex: 0x78350F,
            frameDeepHex: 0x451A03
        ),

        ThemeDefinition(
            id: "oxford_library",
            name: "Oxford Library",
            category: .literary,
            voidHex: 0x0F0C09,
            inkHex: 0xFEF3C7,
            inkDimHex: 0xD97706,
            inkFaintHex: 0x78350F,
            accentHex: 0x15803D,
            accentDeepHex: 0xB45309,
            violetHex: 0xD97706,
            roseHex: 0xB91C1C,
            lanternHex: 0xD97706,
            lanternDeepHex: 0x92400E,
            flameHex: 0xFEF9C3,
            frameHex: 0x78350F,
            frameDeepHex: 0x451A03
        ),

        ThemeDefinition(
            id: "raven",
            name: "The Raven",
            category: .literary,
            voidHex: 0x070609,
            inkHex: 0xE2E8F0,
            inkDimHex: 0x94A3B8,
            inkFaintHex: 0x475569,
            accentHex: 0xDC2626,
            accentDeepHex: 0x7F1D1D,
            violetHex: 0x9333EA,
            roseHex: 0xEF4444,
            lanternHex: 0xDC2626,
            lanternDeepHex: 0x991B1B,
            flameHex: 0xFEE2E2,
            frameHex: 0x52525B,
            frameDeepHex: 0x27272A
        ),

        ThemeDefinition(
            id: "typewriter",
            name: "Vintage Typewriter",
            category: .literary,
            voidHex: 0x141414,
            inkHex: 0xF4F4F5,
            inkDimHex: 0xA1A1AA,
            inkFaintHex: 0x52525B,
            accentHex: 0xEF4444,
            accentDeepHex: 0x71717A,
            violetHex: 0xA1A1AA,
            roseHex: 0xDC2626,
            lanternHex: 0xE4E4E7,
            lanternDeepHex: 0xA1A1AA,
            flameHex: 0xFAFAFA,
            frameHex: 0x71717A,
            frameDeepHex: 0x3F3F46
        ),

        ThemeDefinition(
            id: "alchemy",
            name: "Alchemy",
            category: .literary,
            voidHex: 0x0E0A12,
            inkHex: 0xFAF5FF,
            inkDimHex: 0xC084FC,
            inkFaintHex: 0x6B21A8,
            accentHex: 0xEAB308,
            accentDeepHex: 0xA855F7,
            violetHex: 0x10B981,
            roseHex: 0xF43F5E,
            lanternHex: 0xFACC15,
            lanternDeepHex: 0xCA8A04,
            flameHex: 0xFEF9C3,
            frameHex: 0x9333EA,
            frameDeepHex: 0x581C87
        ),

        ThemeDefinition(
            id: "manuscript",
            name: "Vellum Manuscript",
            category: .literary,
            voidHex: 0x120F0B,
            inkHex: 0xFAF0E6,
            inkDimHex: 0xD4A373,
            inkFaintHex: 0x8D6E63,
            accentHex: 0xF59E0B,
            accentDeepHex: 0x3B82F6,
            violetHex: 0x60A5FA,
            roseHex: 0xEF4444,
            lanternHex: 0xF59E0B,
            lanternDeepHex: 0xB45309,
            flameHex: 0xFFF8E7,
            frameHex: 0x8D6E63,
            frameDeepHex: 0x4E342E
        ),

        // ==========================================
        // 5. CODE & DEVELOPER CLASSICS (10 themes)
        // ==========================================

        ThemeDefinition(
            id: "monokai_pro",
            name: "Monokai Pro",
            category: .developer,
            voidHex: 0x151417,
            inkHex: 0xFCFCFA,
            inkDimHex: 0x939293,
            inkFaintHex: 0x5B595C,
            accentHex: 0xFFD866,
            accentDeepHex: 0xFF6188,
            violetHex: 0xA9DC76,
            roseHex: 0xFF6188,
            lanternHex: 0xFFD866,
            lanternDeepHex: 0xFF6188,
            flameHex: 0xFFFDF5,
            frameHex: 0x78DCE8,
            frameDeepHex: 0x3B7E89
        ),

        ThemeDefinition(
            id: "dracula",
            name: "Dracula",
            category: .developer,
            voidHex: 0x181A20,
            inkHex: 0xF8F8F2,
            inkDimHex: 0x6272A4,
            inkFaintHex: 0x44475A,
            accentHex: 0xBD93F9,
            accentDeepHex: 0xFF79C6,
            violetHex: 0x8BE9FD,
            roseHex: 0xFF5555,
            lanternHex: 0xFF79C6,
            lanternDeepHex: 0xBD93F9,
            flameHex: 0xF8F8F2,
            frameHex: 0x6272A4,
            frameDeepHex: 0x282A36
        ),

        ThemeDefinition(
            id: "nord",
            name: "Nord",
            category: .developer,
            voidHex: 0x11151C,
            inkHex: 0xECEFF4,
            inkDimHex: 0xD8DEE9,
            inkFaintHex: 0x4C566A,
            accentHex: 0x88C0D0,
            accentDeepHex: 0x81A1C1,
            violetHex: 0xB48EAD,
            roseHex: 0xBF616A,
            lanternHex: 0x88C0D0,
            lanternDeepHex: 0x5E81AC,
            flameHex: 0xECEFF4,
            frameHex: 0x4C566A,
            frameDeepHex: 0x2E3440
        ),

        ThemeDefinition(
            id: "solarized_dark",
            name: "Solarized Dark",
            category: .developer,
            voidHex: 0x001217,
            inkHex: 0x839496,
            inkDimHex: 0x93A1A1,
            inkFaintHex: 0x586E75,
            accentHex: 0x2AA198,
            accentDeepHex: 0x268BD2,
            violetHex: 0x6C71C4,
            roseHex: 0xDC322F,
            lanternHex: 0xB58900,
            lanternDeepHex: 0xCB4B16,
            flameHex: 0xFDF6E3,
            frameHex: 0x586E75,
            frameDeepHex: 0x073642
        ),

        ThemeDefinition(
            id: "solarized_light",
            name: "Solarized Light",
            category: .developer,
            isLight: true,
            voidHex: 0xFDF6E3,
            inkHex: 0x073642,
            inkDimHex: 0x586E75,
            inkFaintHex: 0x93A1A1,
            accentHex: 0x268BD2,
            accentDeepHex: 0x2AA198,
            violetHex: 0x6C71C4,
            roseHex: 0xDC322F,
            lanternHex: 0xB58900,
            lanternDeepHex: 0xCB4B16,
            flameHex: 0xEEE8D5,
            frameHex: 0x93A1A1,
            frameDeepHex: 0x657B83
        ),

        ThemeDefinition(
            id: "gruvbox_dark",
            name: "Gruvbox Dark",
            category: .developer,
            voidHex: 0x121212,
            inkHex: 0xEBDBB2,
            inkDimHex: 0xBDAE93,
            inkFaintHex: 0x665C54,
            accentHex: 0xFE8019,
            accentDeepHex: 0xD65D0E,
            violetHex: 0x8EC07C,
            roseHex: 0xFB4934,
            lanternHex: 0xFABD2F,
            lanternDeepHex: 0xFE8019,
            flameHex: 0xFBF1C7,
            frameHex: 0x928374,
            frameDeepHex: 0x3C3836
        ),

        ThemeDefinition(
            id: "one_dark",
            name: "One Dark Pro",
            category: .developer,
            voidHex: 0x14161B,
            inkHex: 0xABB2BF,
            inkDimHex: 0x828997,
            inkFaintHex: 0x5C6370,
            accentHex: 0x61AFEF,
            accentDeepHex: 0x98C379,
            violetHex: 0xC678DD,
            roseHex: 0xE06C75,
            lanternHex: 0xE5C07B,
            lanternDeepHex: 0xD19A66,
            flameHex: 0xECEFF4,
            frameHex: 0x5C6370,
            frameDeepHex: 0x282C34
        ),

        ThemeDefinition(
            id: "catppuccin",
            name: "Catppuccin Mocha",
            category: .developer,
            voidHex: 0x0F0F17,
            inkHex: 0xCDD6F4,
            inkDimHex: 0xBAC2DE,
            inkFaintHex: 0x585B70,
            accentHex: 0xCBA6F7,
            accentDeepHex: 0xB4BEFE,
            violetHex: 0x89B4FA,
            roseHex: 0xF38BA8,
            lanternHex: 0xFAB387,
            lanternDeepHex: 0xF9E2AF,
            flameHex: 0xF5E0DC,
            frameHex: 0x6C7086,
            frameDeepHex: 0x313244
        ),

        ThemeDefinition(
            id: "tokyo_night",
            name: "Tokyo Night",
            category: .developer,
            voidHex: 0x0D0F18,
            inkHex: 0xC0CAF5,
            inkDimHex: 0x7AA2F7,
            inkFaintHex: 0x414868,
            accentHex: 0x7DCFFF,
            accentDeepHex: 0x7AA2F7,
            violetHex: 0xBB9AF7,
            roseHex: 0xF7768E,
            lanternHex: 0xFF9E64,
            lanternDeepHex: 0xE0AF68,
            flameHex: 0xE0AF68,
            frameHex: 0x565F89,
            frameDeepHex: 0x24283B
        ),

        ThemeDefinition(
            id: "github_dark",
            name: "GitHub Dark",
            category: .developer,
            voidHex: 0x0A0D12,
            inkHex: 0xE6EDF3,
            inkDimHex: 0x8D96A0,
            inkFaintHex: 0x484F58,
            accentHex: 0x58A6FF,
            accentDeepHex: 0x3FB950,
            violetHex: 0xBC8CFF,
            roseHex: 0xF85149,
            lanternHex: 0xD29922,
            lanternDeepHex: 0xDB6D28,
            flameHex: 0xF0F6FC,
            frameHex: 0x484F58,
            frameDeepHex: 0x21262D
        ),

        // ==========================================
        // 6. ATMOSPHERIC, SEASONAL & MOOD (7 themes)
        // ==========================================

        ThemeDefinition(
            id: "kyoto_sunset",
            name: "Kyoto Sunset",
            category: .mood,
            voidHex: 0x120914,
            inkHex: 0xFDF4FF,
            inkDimHex: 0xF0ABFC,
            inkFaintHex: 0x701A75,
            accentHex: 0xFB7185,
            accentDeepHex: 0xF59E0B,
            violetHex: 0xC084FC,
            roseHex: 0xE11D48,
            lanternHex: 0xFBBF24,
            lanternDeepHex: 0xF43F5E,
            flameHex: 0xFFF1F2,
            frameHex: 0x86198F,
            frameDeepHex: 0x4A044E
        ),

        ThemeDefinition(
            id: "sakura",
            name: "Sakura Blossom",
            category: .mood,
            voidHex: 0x140910,
            inkHex: 0xFFF1F2,
            inkDimHex: 0xFDA4AF,
            inkFaintHex: 0x9F1239,
            accentHex: 0xF472B6,
            accentDeepHex: 0xFB7185,
            violetHex: 0xE879F9,
            roseHex: 0xF43F5E,
            lanternHex: 0xF472B6,
            lanternDeepHex: 0xDB2777,
            flameHex: 0xFFF5F7,
            frameHex: 0x9D174D,
            frameDeepHex: 0x500724
        ),

        ThemeDefinition(
            id: "midnight_jazz",
            name: "Midnight Jazz",
            category: .mood,
            voidHex: 0x0E0907,
            inkHex: 0xFEF3C7,
            inkDimHex: 0xFDE68A,
            inkFaintHex: 0x78350F,
            accentHex: 0xF59E0B,
            accentDeepHex: 0x3B82F6,
            violetHex: 0x60A5FA,
            roseHex: 0xDC2626,
            lanternHex: 0xF59E0B,
            lanternDeepHex: 0xD97706,
            flameHex: 0xFEF3C7,
            frameHex: 0x92400E,
            frameDeepHex: 0x451A03
        ),

        ThemeDefinition(
            id: "autumn_ember",
            name: "Autumn Ember",
            category: .mood,
            voidHex: 0x140804,
            inkHex: 0xFFEDD5,
            inkDimHex: 0xFDBA74,
            inkFaintHex: 0x7C2D12,
            accentHex: 0xEA580C,
            accentDeepHex: 0xDC2626,
            violetHex: 0xF59E0B,
            roseHex: 0xEF4444,
            lanternHex: 0xF97316,
            lanternDeepHex: 0xC2410C,
            flameHex: 0xFEF3C7,
            frameHex: 0x9A3412,
            frameDeepHex: 0x431407
        ),

        ThemeDefinition(
            id: "lavender_mist",
            name: "Lavender Mist",
            category: .mood,
            voidHex: 0x0D0B14,
            inkHex: 0xF5F3FF,
            inkDimHex: 0xC4B5FD,
            inkFaintHex: 0x5B21B6,
            accentHex: 0xA78BFA,
            accentDeepHex: 0x818CF8,
            violetHex: 0x93C5FD,
            roseHex: 0xF472B6,
            lanternHex: 0xC4B5FD,
            lanternDeepHex: 0x8B5CF6,
            flameHex: 0xFAF5FF,
            frameHex: 0x6D28D9,
            frameDeepHex: 0x3B0764
        ),

        ThemeDefinition(
            id: "paper_light",
            name: "Paper & Carbon (Light)",
            category: .mood,
            isLight: true,
            voidHex: 0xFBFBFC,
            inkHex: 0x18181B,
            inkDimHex: 0x52525B,
            inkFaintHex: 0xA1A1AA,
            accentHex: 0x2563EB,
            accentDeepHex: 0x4F46E5,
            violetHex: 0x7C3AED,
            roseHex: 0xDC2626,
            lanternHex: 0x2563EB,
            lanternDeepHex: 0x1D4ED8,
            flameHex: 0xEFF6FF,
            frameHex: 0x71717A,
            frameDeepHex: 0x3F3F46
        ),

        ThemeDefinition(
            id: "matcha",
            name: "Matcha Latte",
            category: .mood,
            voidHex: 0x0A110D,
            inkHex: 0xF0FDF4,
            inkDimHex: 0x86EFAC,
            inkFaintHex: 0x14532D,
            accentHex: 0x4ADE80,
            accentDeepHex: 0x16A34A,
            violetHex: 0xF59E0B,
            roseHex: 0xF43F5E,
            lanternHex: 0x86EFAC,
            lanternDeepHex: 0x22C55E,
            flameHex: 0xF0FDF4,
            frameHex: 0x2D5A3F,
            frameDeepHex: 0x133420
        )
    ]

    static func themes(in category: ThemeCategory) -> [ThemeDefinition] {
        allThemes.filter { $0.category == category }
    }
}

// MARK: - Theme Manager

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published private(set) var currentTheme: ThemeDefinition {
        didSet {
            UserDefaults.standard.set(currentTheme.id, forKey: "poe.activeThemeId")
            notifyThemeChange()
        }
    }

    private init() {
        let savedId = UserDefaults.standard.string(forKey: "poe.activeThemeId") ?? "abyss"
        self.currentTheme = Theme.allThemes.first { $0.id == savedId } ?? Theme.allThemes[0]
    }

    func setTheme(_ id: String) {
        guard let match = Theme.allThemes.first(where: { $0.id == id }) else { return }
        currentTheme = match
    }

    func nextTheme() {
        guard let idx = Theme.allThemes.firstIndex(where: { $0.id == currentTheme.id }) else { return }
        let nextIdx = (idx + 1) % Theme.allThemes.count
        currentTheme = Theme.allThemes[nextIdx]
    }

    func previousTheme() {
        guard let idx = Theme.allThemes.firstIndex(where: { $0.id == currentTheme.id }) else { return }
        let prevIdx = (idx - 1 + Theme.allThemes.count) % Theme.allThemes.count
        currentTheme = Theme.allThemes[prevIdx]
    }

    func randomTheme() {
        let others = Theme.allThemes.filter { $0.id != currentTheme.id }
        if let random = others.randomElement() {
            currentTheme = random
        }
    }

    private func notifyThemeChange() {
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.backgroundColor = NSColor(self.currentTheme.void)
                window.appearance = self.currentTheme.isLight ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)
            }
        }
    }
}

// MARK: - Dynamic Theme Facade

/// The whole visual language: dynamically backed by the active `ThemeDefinition`.
enum Theme {
    static var current: ThemeDefinition { ThemeManager.shared.currentTheme }

    static var void: Color { current.void }
    static var panel: Color { current.panel }
    static var panelStroke: Color { current.panelStroke }
    static var hairline: Color { current.hairline }
    static var codePanel: Color { current.codePanel }

    static var ink: Color { current.ink }
    static var inkDim: Color { current.inkDim }
    static var inkFaint: Color { current.inkFaint }

    static var accent: Color { current.accent }
    static var accentDeep: Color { current.accentDeep }
    static var violet: Color { current.violet }
    static var rose: Color { current.rose }

    static var lantern: Color { current.lantern }
    static var lanternDeep: Color { current.lanternDeep }
    static var flame: Color { current.flame }
    static var frame: Color { current.frame }
    static var frameDeep: Color { current.frameDeep }

    static var glow: LinearGradient {
        LinearGradient(
            colors: [current.accent, current.accentDeep, current.violet],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static let editorFont = NSFont(name: "SF Mono", size: 15)
        ?? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
}

// MARK: - Glass Panel & View Modifiers

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

// MARK: - Formatters & Extensions

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
