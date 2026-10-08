import AgentDeckCore
import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--statusline") {
            exit(StatusLineCommand.run())
        }
        if let index = arguments.firstIndex(of: "--render-menu"), arguments.indices.contains(index + 1) {
            let status = MainActor.assumeIsolated { MenuRenderer.run(output: arguments[index + 1], arguments: arguments) }
            exit(status)
        }
        AgentDeckApp.main()
    }
}

/// `AgentDeck --statusline`: Claude Code's status line command. Claude Code pipes its session state
/// in as JSON; AgentDeck keeps only `rate_limits` (Claude's own usage percentages) for the Limits tab
/// and prints them as the status line text.
enum StatusLineCommand {
    static func run() -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let limits = ClaudeReportedLimits.extract(statusLineInput: input, now: Date())
        // When it last ran, and whether Claude Code sent limits, so the app can tell "never runs"
        // from "runs without limits". Only the top-level key names are kept, never their values.
        let keys = ((try? JSONSerialization.jsonObject(with: input)) as? [String: Any]).map { $0.keys.sorted() } ?? []
        let heartbeat = "\(ISO8601DateFormatter().string(from: Date())) limits=\(limits != nil) keys=\(keys.joined(separator: ","))\n"
        try? heartbeat.write(to: AgentDeckPaths.home.appendingPathComponent("statusline-last-run.txt"), atomically: true, encoding: .utf8)
        guard let limits else { return 0 }
        try? limits.write()
        print(limits.statusText)
        return 0
    }
}

/// A menu bar app shows nothing when opened. So the first launch drops down its panel under the menu
/// bar icon, and opening the app again (Finder, Spotlight, `open`) shows the AgentDeck window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.warnIfMenuBarItemIsHidden() }
        }
        let key = "openedPanelOnFirstLaunch"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MenuBarPanel.open() }
    }

    /// Notches hide menu bar items that do not fit. Checked once after launch, when the item has
    /// its final place; a notification explains how to bring it back.
    @MainActor private func warnIfMenuBarItemIsHidden() {
        guard let item = NSApp.windows.first(where: { $0.className.contains("StatusBar") }) else { return }
        let displays = NSScreen.screens.map {
            MenuBarGeometry.Display(frame: $0.frame, leftOfNotch: $0.auxiliaryTopLeftArea, rightOfNotch: $0.auxiliaryTopRightArea)
        }
        guard MenuBarGeometry.isHidden(item: item.frame, displays: displays) else { return }
        Task {
            _ = await Notifier.requestAuthorization()
            Notifier.post(.init(title: "AgentDeck's menu bar icon is hidden",
                                body: "The menu bar is full, so macOS put the icon behind the notch. Quit or hide another menu bar app, or hold ⌘ and drag AgentDeck's icon to the right. Opening AgentDeck again also shows its panel."))
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NotificationCenter.default.post(name: MainWindow.openRequest, object: nil)
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

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: Self.icon)
            if model.settings.showUsageInMenuBar {
                Text(model.menuBarTitle).monospacedDigit()
            }
        }
        .accessibilityLabel("AgentDeck")
        // The label lives as long as the app, so it relays the app delegate's requests to SwiftUI.
        .onReceive(NotificationCenter.default.publisher(for: MainWindow.openRequest)) { _ in
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: MainWindow.id)
        }
    }
}

/// The same content as the dropdown in a resizable window. While it is open AgentDeck shows in the
/// Dock and the app switcher like a normal app.
struct MainWindow: View {
    static let id = "main"
    static let openRequest = Notification.Name("AgentDeck.openMainWindow")
    let model: AppModel

    var body: some View {
        MenuContentView(model: model, inWindow: true)
            .background(TransparentWindow())
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            .onDisappear { NSApp.setActivationPolicy(.accessory) }
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

        Window("AgentDeck", id: MainWindow.id) {
            MainWindow(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 820)
        .windowResizability(.contentMinSize)

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
