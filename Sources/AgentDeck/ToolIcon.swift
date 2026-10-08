import AgentDeckCore
import AppKit
import SwiftUI

/// Claude Code's and Codex's own icons, read from the apps installed on this Mac (Claude.app, and
/// the ChatGPT app that bundles Codex), so AgentDeck ships no logos of its own. A symbol stands in
/// when an app is not installed.
@MainActor
enum ToolIcons {
    private static var cache: [SkillTarget: NSImage?] = [:]

    static func image(for target: SkillTarget) -> NSImage? {
        if let cached = cache[target] { return cached }
        let bundleID = switch target {
        case .claudeCode: "com.anthropic.claudefordesktop"
        case .codex: "com.openai.codex"
        }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[target] = image
        return image
    }

    static func name(_ target: SkillTarget) -> String {
        target == .claudeCode ? "Claude Code" : "Codex"
    }
}

/// A tool's icon at text size. Inactive icons are grey and faint, so a row reads at a glance.
struct ToolIcon: View {
    let target: SkillTarget
    var isActive = true
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = ToolIcons.image(for: target) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: target == .claudeCode ? "asterisk.circle.fill" : "terminal.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .saturation(isActive ? 1 : 0)
        .opacity(isActive ? 1 : 0.3)
        .accessibilityLabel(ToolIcons.name(target))
    }
}
