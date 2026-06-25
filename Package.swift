// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentSession",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "AgentSession",
            resources: [.copy("Resources/template.html")]
        ),
        .testTarget(
            name: "AgentSessionTests",
            dependencies: ["AgentSession"]
        )
    ]
)
