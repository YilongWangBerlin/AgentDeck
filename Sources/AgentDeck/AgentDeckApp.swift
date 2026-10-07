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

        Settings {
            SettingsView(model: model)
        }
    }
}

/// `AgentDeck --render-menu OUT.png --db PATH [--dark]`: scans the logs into the given database and
/// writes the menu as a PNG, so the layout can be checked without opening the menu bar.
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
        let view = MenuContentView(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
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
