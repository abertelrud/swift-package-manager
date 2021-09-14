// swift-tools-version:5.6
import PackageDescription

let package = Package(
    name: "UserCommandPlugin",
    products: [
        .library(
            name: "UserCommandPlugin",
            targets: ["UserCommandPlugin"]
        ),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "UserCommandPlugin",
            dependencies: []
        ),
        .testTarget(
            name: "UserCommandPluginTests",
            dependencies: ["UserCommandPlugin"]
        ),
        .plugin(
            name: "MyUserCommand",
            capability: .userCommand(
                intent: .documentationGeneration,
                workflowStage: .afterBuilding(requirements: [.symbolGraph])
            )
        )
    ]
)
