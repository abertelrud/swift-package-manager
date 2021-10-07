import PackagePlugin

@main
struct MyUserCommandPlugin: UserCommandPlugin {
    func performUserCommand(
        context: PluginContext,
        targets: [Target],
        arguments: [String]
    ) throws {
        print("performing user command for targets: \(targets.map{ $0.name }.joined(separator: ", "))")
    }
}