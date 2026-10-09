import SwiftUI

/// A color scheme for the whole UI, chosen in Settings. Each has a light and a dark variant that
/// follow the system appearance.
enum Theme: String, Codable, CaseIterable, Identifiable {
    case classic, claude, forest, lavender, graphite

    var id: String { rawValue }

    var name: String {
        switch self {
        case .classic: "Classic"
        case .claude: "Claude"
        case .forest: "Forest"
        case .lavender: "Lavender"
        case .graphite: "Graphite"
        }
    }

    /// One color as a light/dark pair of RGB values.
    struct Pair {
        var light: UInt32
        var dark: UInt32
        var color: Color { Color(light: light, dark: dark) }
    }

    struct Colors {
        /// Laid over the blur: decides how light or dark the glass is.
        var glass: Pair
        /// Cards, chips and bar tracks are this color at low opacity.
        var cardBase: Pair = Pair(light: 0xFFFFFF, dark: 0xFFFFFF)
        var ink: Pair = Pair(light: 0x000000, dark: 0xFFFFFF)
        /// Nil keeps the system accent color.
        var accent: Pair?
        /// Heatmap levels 1–4 (level 0 is the empty tile).
        var heat: [Pair]
        var input: Pair
        var output: Pair
        var cache: Pair
    }

    var colors: Colors {
        switch self {
        case .classic:
            Colors(
                glass: Pair(light: 0xF7F7F5, dark: 0x18181A),
                heat: [Pair(light: 0x8FADE8, dark: 0x2F4C7E), Pair(light: 0x6E95E0, dark: 0x3D66AE),
                       Pair(light: 0x4F7DD9, dark: 0x5583D6), Pair(light: 0x3463CF, dark: 0x7EA6F0)],
                input: Pair(light: 0x4F7DD9, dark: 0x6E95E0),
                output: Pair(light: 0xE08A3C, dark: 0xF0A060),
                cache: Pair(light: 0xB8C4D6, dark: 0x4A5568)
            )
        case .claude:
            // Claude's warm paper and clay.
            Colors(
                glass: Pair(light: 0xF5F0E6, dark: 0x262624),
                cardBase: Pair(light: 0xFFFDF8, dark: 0xFAF5EC),
                ink: Pair(light: 0x3D3929, dark: 0xF5F0E6),
                accent: Pair(light: 0xC96442, dark: 0xD97757),
                heat: [Pair(light: 0xF0CDB9, dark: 0x5A3326), Pair(light: 0xE6A685, dark: 0x8A4A33),
                       Pair(light: 0xD97757, dark: 0xC0603F), Pair(light: 0xB4532F, dark: 0xEC9472)],
                input: Pair(light: 0xC96442, dark: 0xD97757),
                output: Pair(light: 0x7D8F69, dark: 0xA3B58C),
                cache: Pair(light: 0xDCD3C4, dark: 0x5A544A)
            )
        case .forest:
            Colors(
                glass: Pair(light: 0xF1F5EF, dark: 0x161C18),
                cardBase: Pair(light: 0xFBFDFA, dark: 0xF1F8F2),
                accent: Pair(light: 0x2F8F5B, dark: 0x4CC38A),
                heat: [Pair(light: 0xB7DFC3, dark: 0x1F4A31), Pair(light: 0x7FC79A, dark: 0x2C6B45),
                       Pair(light: 0x43A86E, dark: 0x3E9A62), Pair(light: 0x22784A, dark: 0x66CC8E)],
                input: Pair(light: 0x2F8F5B, dark: 0x4CC38A),
                output: Pair(light: 0xC99A1E, dark: 0xE6C35C),
                cache: Pair(light: 0xC2CFC4, dark: 0x46524A)
            )
        case .lavender:
            Colors(
                glass: Pair(light: 0xF5F3FA, dark: 0x1B1922),
                cardBase: Pair(light: 0xFDFCFF, dark: 0xF4F0FF),
                accent: Pair(light: 0x7B5BD6, dark: 0xA28BF0),
                heat: [Pair(light: 0xD6CCF5, dark: 0x352B5C), Pair(light: 0xB3A1EC, dark: 0x4D3E86),
                       Pair(light: 0x8E74DE, dark: 0x6F5BC0), Pair(light: 0x6A4BC7, dark: 0x9D88EE)],
                input: Pair(light: 0x7B5BD6, dark: 0xA28BF0),
                output: Pair(light: 0xD9628F, dark: 0xF08DB3),
                cache: Pair(light: 0xCBC6D9, dark: 0x4D4860)
            )
        case .graphite:
            Colors(
                glass: Pair(light: 0xF4F4F4, dark: 0x141414),
                accent: Pair(light: 0x3A3A3C, dark: 0xAEAEB2),
                heat: [Pair(light: 0xCFCFD1, dark: 0x3A3A3C), Pair(light: 0xA3A3A6, dark: 0x5E5E62),
                       Pair(light: 0x6E6E72, dark: 0x8E8E93), Pair(light: 0x3A3A3C, dark: 0xD1D1D6)],
                input: Pair(light: 0x48484A, dark: 0xD1D1D6),
                output: Pair(light: 0xE08A3C, dark: 0xF0A060),
                cache: Pair(light: 0xC7C7CC, dark: 0x48484A)
            )
        }
    }
}

/// The current theme's colors. Views read these directly; the menu's root view is rebuilt when the
/// theme changes (`.id`), so nothing caches an old color.
@MainActor
enum Palette {
    static var theme = Theme.classic

    private static var colors: Theme.Colors { theme.colors }

    static var glassTint: Color {
        Color(light: colors.glass.light, dark: colors.glass.dark, lightAlpha: 0.62, darkAlpha: 0.66)
    }
    /// Cards on the glass.
    static var card: Color {
        Color(light: colors.cardBase.light, dark: colors.cardBase.dark, lightAlpha: 0.66, darkAlpha: 0.06)
    }
    static var hairline: Color {
        Color(light: colors.ink.light, dark: colors.ink.dark, lightAlpha: 0.08, darkAlpha: 0.10)
    }
    /// Chips, bar tracks and empty heatmap days.
    static var tile: Color {
        Color(light: colors.ink.light, dark: colors.ink.dark, lightAlpha: 0.06, darkAlpha: 0.09)
    }
    static var accent: Color { colors.accent?.color ?? .accentColor }
    static var heat: [Color] { [tile] + colors.heat.map(\.color) }
    static var input: Color { colors.input.color }
    static var output: Color { colors.output.color }
    static var cache: Color { colors.cache.color }
    /// Warnings in text: darker than system orange in light mode so it reads on the glass.
    static let warning = Color(light: 0xB45309, dark: 0xF5A524)
}
