// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "ExpandedAPIsTestPlugin",
    dependencies: [
        .package(path: "../MySourceGenPlugin")
    ],
    targets: [
        // A tool that uses a plugin.
        .executableTarget(
            name: "MyTool",
            plugins: [
                .plugin(name: "MySourceGenBuildToolPlugin", package: "MySourceGenPlugin"),
                .plugin(name: "MyExpandedAPIsTestPlugin")
            ]
        ),
        // A unit test that uses the plugin.
        .testTarget(
            name: "MyTests",
            plugins: [
                .plugin(name: "MySourceGenBuildToolPlugin", package: "MySourceGenPlugin")
            ]
        ),
        // The plugin that emits various information from the additional APIs.
        .plugin(
            name: "MyExpandedAPIsTestPlugin",
            capability: .buildTool()
        ),
    ]
)
