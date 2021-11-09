import PackagePlugin

@main
struct MyExpandedAPIsTestPlugin: BuildToolPlugin {
    
    func createBuildCommands(context: TargetBuildContext) throws -> [Command] {
        print("Hello from the Build Tool Plugin!")
        return []
    }
}
