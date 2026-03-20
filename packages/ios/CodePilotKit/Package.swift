// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodePilotKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "CodePilotProtocol", targets: ["CodePilotProtocol"]),
        .library(name: "CodePilotCore", targets: ["CodePilotCore"]),
        .library(name: "CodePilotFeatures", targets: ["CodePilotFeatures"]),
    ],
    targets: [
        .target(
            name: "CodePilotProtocol",
            path: "Sources/CodePilotProtocol"
        ),
        .target(
            name: "CodePilotCore",
            dependencies: ["CodePilotProtocol"],
            path: "Sources/CodePilotCore"
        ),
        .target(
            name: "CodePilotFeatures",
            dependencies: ["CodePilotCore", "CodePilotProtocol"],
            path: "Sources/CodePilotFeatures"
        ),
        .testTarget(
            name: "CodePilotProtocolTests",
            dependencies: ["CodePilotProtocol"]
        ),
        .testTarget(
            name: "CodePilotCoreTests",
            dependencies: ["CodePilotCore", "CodePilotProtocol"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "CodePilotFeaturesTests",
            dependencies: ["CodePilotFeatures", "CodePilotCore", "CodePilotProtocol"]
        ),
    ]
)
