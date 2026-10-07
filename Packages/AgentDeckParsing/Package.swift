// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentDeckParsing",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentDeckParsing", targets: ["AgentDeckParsing"]),
        .executable(name: "adparse", targets: ["adparse"]),
    ],
    targets: [
        .target(name: "AgentDeckParsing"),
        .executableTarget(name: "adparse", dependencies: ["AgentDeckParsing"]),
        .testTarget(
            name: "AgentDeckParsingTests",
            dependencies: ["AgentDeckParsing"],
            exclude: ["Fixtures"]
        ),
    ]
)
