import Foundation

/// Number and duration formats shared by the menu bar, the dashboard and the published cards.
public enum Formatting {
    /// `950`, `12.3K`, `54.2M`, `478M`, `2.4B`. One decimal below 100, trailing `.0` dropped.
    public static func compactTokens(_ value: Int) -> String {
        let units: [(scale: Double, suffix: String)] = [(1e3, "K"), (1e6, "M"), (1e9, "B"), (1e12, "T")]
        let magnitude = abs(Double(value))
        guard var index = units.lastIndex(where: { magnitude >= $0.scale }) else { return "\(value)" }
        // Rounding can carry into the next unit (999,960 would print as 1000K); use the larger unit.
        if magnitude / units[index].scale >= 999.5, index + 1 < units.count { index += 1 }
        let scaled = Double(value) / units[index].scale
        let text = abs(scaled) < 99.95 ? String(format: "%.1f", scaled) : String(format: "%.0f", scaled)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + units[index].suffix
    }

    /// `3d 4h`, `2h 47m`, `47m`, `<1m`. Negative intervals read as `0m`.
    public static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int((max(0, interval) / 60).rounded(.down))
        if interval > 0, minutes == 0 { return "<1m" }
        let days = minutes / 1440, hours = (minutes % 1440) / 60, rest = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(rest)m" }
        return "\(rest)m"
    }

    /// Short form for the menu bar: `2h47`, `47m`, `3d`.
    public static func shortDuration(_ interval: TimeInterval) -> String {
        let minutes = Int((max(0, interval) / 60).rounded(.down))
        if minutes >= 1440 { return "\(minutes / 1440)d" }
        if minutes >= 60 { return String(format: "%dh%02d", minutes / 60, minutes % 60) }
        return "\(minutes)m"
    }
}
