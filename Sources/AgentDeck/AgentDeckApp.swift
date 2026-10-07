import AgentDeckCore
import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        for target in MenuRenderer.Target.allCases {
            if let index = arguments.firstIndex(of: "--render-\(target.rawValue)"), arguments.indices.contains(index + 1) {
                let status = MainActor.assumeIsolated {
                    MenuRenderer.run(target, output: arguments[index + 1], arguments: arguments)
                }
                exit(status)
            }
        }
        AgentDeckApp.main()
    }
}

struct AgentDeckApp: App {
    @State private var model: AppModel = {
        let model = AppModel()
        model.start()
        return model
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Text(model.menuBarTitle).monospacedDigit()
        }
        .menuBarExtraStyle(.window)

        Window("AgentDeck", id: "dashboard") {
            DashboardView(model: model.dashboard, skills: model.skills, skillLocations: model.skillLocations)
        }
        .defaultSize(width: 820, height: 600)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// `AgentDeck --render-menu|--render-dashboard OUT.png --db PATH [--dark] [--models]`: scans the logs
/// into the given database and writes the view as a PNG, so layouts can be checked without a screen.
@MainActor
enum MenuRenderer {
    enum Target: String, CaseIterable { case menu, dashboard }

    static func run(_ target: Target, output: String, arguments: [String]) -> Int32 {
        guard let dbIndex = arguments.firstIndex(of: "--db"), arguments.indices.contains(dbIndex + 1) else {
            print("--render-menu needs --db PATH (a scratch database, not the real one)")
            return 2
        }
        let model = AppModel(databaseURL: URL(fileURLWithPath: arguments[dbIndex + 1]))
        model.scanNow()

        let dark = arguments.contains("--dark")
        if arguments.contains("--models") { model.dashboard.tab = .models }
        if arguments.contains("--skills") {
            model.dashboard.tab = .skills
            let done = DispatchSemaphore(value: 0)
            Task.detached { await model.skills.scan(locations: await model.skillLocations); done.signal() }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        let content: AnyView = switch target {
        case .menu: AnyView(MenuContentView(model: model).background(Color(nsColor: .windowBackgroundColor)))
        case .dashboard: AnyView(DashboardView(model: model.dashboard, skills: model.skills, skillLocations: model.skillLocations).frame(width: 820))
        }
        let view = content
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
