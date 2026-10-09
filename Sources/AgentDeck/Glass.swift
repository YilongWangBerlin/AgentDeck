import AppKit
import SwiftUI

/// Frosted glass: the system blur of whatever is behind the window, under a tint strong enough to
/// keep text readable over any backdrop (a dark panel over a white window otherwise turns muddy
/// grey).
struct GlassBackground: View {
    @Environment(\.isRenderingSnapshot) private var isRenderingSnapshot

    var body: some View {
        ZStack {
            // Offscreen rendering cannot draw the blur; the tint alone stands in for it.
            if !isRenderingSnapshot { VisualEffect() }
            Palette.glassTint
        }
        .ignoresSafeArea()
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    /// A translucent rounded panel with a hairline edge, for grouping content on the glass.
    func glassCard(cornerRadius: CGFloat = 12, padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }
}

/// Lets a SwiftUI window show the glass: no opaque background, a transparent title bar, and content
/// running under it.
struct TransparentWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// A quiet button for the glass: a soft capsule that darkens on hover and press, instead of the
/// opaque bezel of the standard style.
struct GlassButtonStyle: ButtonStyle {
    var iconOnly = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(.horizontal, iconOnly ? 6 : 10)
            .padding(.vertical, 4)
            .background {
                ZStack {
                    Capsule().fill(Palette.tile)
                    if hovering || configuration.isPressed { Capsule().fill(Palette.tile) }
                    if configuration.isPressed { Capsule().fill(Palette.tile) }
                }
            }
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

/// True in the standalone window: tabs grow with the window instead of using the dropdown's fixed
/// height.
struct DashboardFillsHeightKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var dashboardFillsHeight: Bool {
        get { self[DashboardFillsHeightKey.self] }
        set { self[DashboardFillsHeightKey.self] = newValue }
    }
}

/// A switch drawn in SwiftUI, matching the glass look (and visible in offscreen renders, which
/// cannot draw the system switch).
struct GlassSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.label
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Palette.tile))
                    .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: 30, height: 18)
            .animation(.easeOut(duration: 0.15), value: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}
