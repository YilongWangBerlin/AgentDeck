// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentDeck", targets: ["AgentDeck"]),
        .executable(name: "adingest", targets: ["adingest"]),
        .executable(name: "adexport", targets: ["adexport"]),
    ],
    dependencies: [
        .package(path: "Packages/AgentDeckParsing"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "AgentDeckCore",
            dependencies: [
                "AgentDeckParsing",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(name: "AgentDeck", dependencies: ["AgentDeckCore"]),
        .executableTarget(name: "adingest", dependencies: ["AgentDeckCore"]),
        .executableTarget(name: "adexport", dependencies: ["AgentDeckCore"]),
        .testTarget(name: "AgentDeckCoreTests", dependencies: ["AgentDeckCore"]),
    ]
)
