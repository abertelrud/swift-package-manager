import PackagePlugin

@main
struct MyUserCommandPlugin: UserCommandPlugin {
    func performUserCommand(
        context: PluginContext,
        targets: [Target],
        arguments: [String]
    ) throws {
        for target in targets {
            // Skip any target that doesn't have source files.
            guard let target = target as? SourceModuleTarget else { continue }
            
            // Get the .docc files in the target.
            let doccFiles = target.sourceFiles.filter { $0.path.extension == "docc" }
            
            // Skip any target that doesn't have .docc files.
            if doccFiles.isEmpty { continue }
            
            // Ask SwiftPM to generate or update symbol graph files for the target.
            let symbolGraphDir = try context.getSymbolGraphDirectory(for: target, options: .init(minimumAccessLevel: .public))
            print("symbol graph dir for target ‘\(target.name)’ is ‘\(symbolGraphDir)’")
            
            // Iterate over any .docc files
            for docc in target.sourceFiles.filter { $0.path.extension == "docc" } {
                print(docc)
            }
            
            // let output = try context.invokeToolchainCommand(named: "docc", arguments: ["help", "preview"])
            // print(output)
        }
    }
}



