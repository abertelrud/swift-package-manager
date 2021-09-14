import PackagePlugin

@main
struct MyUserCommandPlugin: UserCommandPlugin {
    func performUserCommand(
        context: PluginContext,
        targets: [Target],
        arguments: [String]
    ) throws -> [Command] {
        print("performing user command for targets: \(targets.map{ $0.name }.joined(separator: ", "))")
        return [.userCommand(
            displayName: "Running docc",
            executable: "/the/path/to/docc",
            arguments: [])
        ]
    }
}