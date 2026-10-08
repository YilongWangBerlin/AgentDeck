import AgentDeckCore
import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--render-menu"), arguments.indices.contains(index + 1) {
            let status = MainActor.assumeIsolated { MenuRenderer.run(output: arguments[index + 1], arguments: arguments) }
            exit(status)
        }
        AgentDeckApp.main()
    }
}

/// A menu bar app shows nothing when opened. So the first launch, and opening the app again (Finder,
/// Spotlight, `open`), drop down its panel under the menu bar icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let key = "openedPanelOnFirstLaunch"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MenuBarPanel.open() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MenuBarPanel.open()
        return false
    }
}

/// Opens the dropdown by clicking AgentDeck's own status item, unless it is already showing.
@MainActor
enum MenuBarPanel {
    static func open() {
        let statusWindows = NSApp.windows.filter { $0.className.contains("StatusBar") }
        let panelIsOpen = NSApp.windows.contains { $0.isVisible && !statusWindows.contains($0) && $0.level.rawValue > NSWindow.Level.normal.rawValue }
        guard !panelIsOpen else { return }
        for window in statusWindows {
            if let button = button(in: window.contentView) {
                button.performClick(nil)
                return
            }
        }
    }

    /// Runs an open or save panel from the dropdown. The panel goes above the dropdown (which floats
    /// over normal windows), and the dropdown is opened again afterwards in case it closed when the
    /// panel took focus.
    static func runModal(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        let dropdownLevel = NSApp.windows.filter(\.isVisible).map(\.level.rawValue).max() ?? NSWindow.Level.normal.rawValue
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.modalPanel.rawValue, dropdownLevel + 1))
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        DispatchQueue.main.async { open() }
        return response
    }

    private static func button(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        return view.subviews.lazy.compactMap { button(in: $0) }.first
    }
}

/// The AgentDeck icon (a template image, so macOS tints it for light and dark menu bars), optionally
/// followed by the 5-hour usage text.
struct MenuBarLabel: View {
    let model: AppModel

    @MainActor static let icon: NSImage = {
        let image = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "AgentDeck")!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: Self.icon)
            if model.settings.showUsageInMenuBar {
                Text(model.menuBarTitle).monospacedDigit()
            }
        }
        .accessibilityLabel("AgentDeck")
    }
}

struct AgentDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel = {
        let model = AppModel()
        model.start()
        return model
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// `AgentDeck --render-menu OUT.png --db PATH [--dark] [--limits|--models|--skills|--publish]`: scans the
/// logs into the given database and writes the dropdown as a PNG, so layouts can be checked without a
/// screen. Without a tab flag it shows Overview.
@MainActor
enum MenuRenderer {
    static func run(output: String, arguments: [String]) -> Int32 {
        guard let dbIndex = arguments.firstIndex(of: "--db"), arguments.indices.contains(dbIndex + 1) else {
            print("--render-menu needs --db PATH (a scratch database, not the real one)")
            return 2
        }
        let model = AppModel(databaseURL: URL(fileURLWithPath: arguments[dbIndex + 1]))
        model.scanNow()

        let dark = arguments.contains("--dark")
        for tab in DashboardModel.Tab.allCases where arguments.contains("--\(tab.rawValue.lowercased())") {
            model.dashboard.tab = tab
        }
        if arguments.contains("--skills") {
            model.dashboard.tab = .skills
            let done = DispatchSemaphore(value: 0)
            Task.detached { await model.skills.scan(locations: await model.skillLocations); done.signal() }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        let view = MenuContentView(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.isRenderingSnapshot, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            print("rendering failed")
            return 1
        }
        do {
            try png.write(to: URL(fileURLWithPath: output))
        } catch {
            print("could not write \(output): \(error)")
            return 1
        }
        print("menu bar title: \(model.menuBarTitle)")
        return 0
    }
}
