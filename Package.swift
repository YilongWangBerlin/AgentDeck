// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentDeck", targets: ["AgentDeck"]),
        .executable(name: "AgentDeckWidget", targets: ["AgentDeckWidget"]),
        .executable(name: "adingest", targets: ["adingest"]),
        .executable(name: "adexport", targets: ["adexport"]),
        .executable(name: "adskills", targets: ["adskills"]),
    ],
    dependencies: [
        .package(path: "Packages/AgentDeckParsing"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // What the widget reads. No dependencies, so the widget stays small.
        .target(name: "AgentDeckWidgetData"),
        .target(
            name: "AgentDeckCore",
            dependencies: [
                "AgentDeckParsing",
                "AgentDeckWidgetData",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(name: "AgentDeck", dependencies: ["AgentDeckCore"]),
        // The desktop widget. scripts/build-app.sh wraps it in an app extension bundle.
        // Like Xcode's app extension targets, it starts at _NSExtensionMain: with a plain `main`
        // entry, the process exits as soon as chronod launches it and the widget never appears
        // in the gallery.
        .executableTarget(
            name: "AgentDeckWidget",
            dependencies: ["AgentDeckWidgetData"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(name: "adingest", dependencies: ["AgentDeckCore"]),
        .executableTarget(name: "adexport", dependencies: ["AgentDeckCore"]),
        .executableTarget(name: "adskills", dependencies: ["AgentDeckCore"]),
        .testTarget(name: "AgentDeckCoreTests", dependencies: ["AgentDeckCore"]),
    ]
)
