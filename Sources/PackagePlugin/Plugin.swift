/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

/*
   This source file contains the main entry point for all plugins. It decodes
   input from SwiftPM, determines which protocol function to call, and finally
   encodes output for SwiftPM.
*/

@_implementationOnly import Foundation

// The way in which SwiftPM communicates with the plugin is an implementation
// detail, but the way it currently works is that the plugin is compiled (in
// a very similar way to the package manifest) and then run in a sandbox.
//
// Currently the plugin input is provided in the form of a JSON-encoded input
// structure passed as the last command line argument; however, this will very
// likely change so that it is instead passed on `stdin` of the process that
// runs the plugin, since that avoids any command line length limitations.
//
// Any generated commands and diagnostics are emitted on `stdout` after a zero
// byte; this allows regular output, such as print statements for debugging,
// to be emitted to SwiftPM verbatim. SwiftPM tries to interpret any stdout
// contents after the last zero byte as a JSON encoded output struct in UTF-8
// encoding; any failure to decode it is considered a protocol failure.
//
// The exit code of the compiled plugin determines success or failure (though
// failure to decode the output is also considered a failure to run the ex-
// tension).

extension Plugin {
    
    public static func main(_ arguments: [String]) throws {
        // Get the path of the output JSON file (via an environment variable,
        // since the arguments contain the plugin's custom arguments). Note
        // that the use of the environment here is an implementation detail
        // that doesn't affect the plugin source code.
        guard let outputPath = ProcessInfo.processInfo.environment["__SWIFTPM_PLUGIN_OUTPUT_FILE_PATH__"] else {
            fputs("Internal Error: Expected but didn’t find '__SWIFTPM_PLUGIN_OUTPUT_FILE_PATH__' in environment.", stderr)
            Diagnostics.error("Internal Error: Expected but didn’t find '__SWIFTPM_PLUGIN_OUTPUT_FILE_PATH__' in environment.")
            exit(1)
        }
        
        // Unset it in the environment so that it doesn't affect the plugin,
        // in case it looks around in the environment.
        unsetenv("__SWIFTPM_PLUGIN_OUTPUT_FILE_PATH__")
        
        // Get the path of the input JSON file (via an environment variable,
        // since the arguments contain the plugin's custom arguments). Note
        // that the use of the environment here is an implementation detail
        // that doesn't affect the plugin source code.
        guard let inputPath = ProcessInfo.processInfo.environment["__SWIFTPM_PLUGIN_INPUT_FILE_PATH__"] else {
            fputs("Internal Error: Expected but didn’t find '__SWIFTPM_PLUGIN_INPUT_FILE_PATH__' in environment.", stderr)
            Diagnostics.error("Internal Error: Expected but didn’t find '__SWIFTPM_PLUGIN_INPUT_FILE_PATH__' in environment.")
            exit(1)
        }
        
        // Unset it in the environment so that it doesn't affect the plugin,
        // in case it looks around in the environment.
        unsetenv("__SWIFTPM_PLUGIN_INPUT_FILE_PATH__")
        
        // Open the input JSON file and read its contents.
        let inputData: Data
        do {
            try inputData = Data(contentsOf: URL(fileURLWithPath: inputPath))
        }
        catch {
            Diagnostics.error("Internal Error: Couldn’t open input file '\(inputPath): \(error)'.")
            exit(1)
        }

        // Deserialize the input JSON.
        let input = try PluginInput(from: inputData)
        
        // Construct a PluginContext from the deserialized input.
        var context = PluginContext(
            package: input.package,
            pluginWorkDirectory: input.pluginWorkDirectory,
            builtProductsDirectory: input.builtProductsDirectory,
            toolNamesToPaths: input.toolNamesToPaths)
        
        // Instantiate the plugin. For now there are no parameters, but this is
        // where we would set them up, most likely as properties of the plugin
        // instance (in a manner similar to SwiftArgumentParser).
        let plugin = self.init()
        
        // Invoke the appropriate protocol method, based on the plugin action
        // that SwiftPM specified.
        let commands: [Command]
        switch input.pluginAction {
        
        case .createBuildToolCommands(let target):
            // Check that the plugin implements the appropriate protocol for its
            // declared capability.
            guard let plugin = plugin as? BuildToolPlugin else {
                throw PluginDeserializationError.malformedInputJSON("Plugin declared with `buildTool` capability but doesn't conform to `BuildToolPlugin` protocol")
            }
            
            // Ask the plugin to create build commands for the input target.
            commands = try plugin.createBuildCommands(context: context, target: target)
            
        case .performUserCommand(let targets, let arguments, let targetNamesToEncodedBuildInfos):
            // Check that the plugin implements the appropriate protocol for its
            // declared capability.
            guard let plugin = plugin as? UserCommandPlugin else {
                throw PluginDeserializationError.malformedInputJSON("Plugin declared with `userCommand` capability but doesn't conform to `UserCommandPlugin` protocol")
            }
            
            // For now, set the mapping of target names to build info in the context. This will later go away, instead communicating back to SwiftPM to get this information dynamically.
            context.targetNamesToEncodedBuildInfos = targetNamesToEncodedBuildInfos
            
            // Invoke the plugin.
            try plugin.performUserCommand(context: context, targets: targets, arguments: arguments)

            // For user commands there are currently no return commands (whatever the plugin does, it invokes directly).
            commands = []
        }
        
        // Construct the output structure to send to SwiftPM.
        let output = try PluginOutput(commands: commands, diagnostics: Diagnostics.emittedDiagnostics)

        // Write the output data to a file at the path provided by the environment variable.
        // FIXME: Handle errors
        FileManager.default.createFile(atPath: outputPath, contents: output.outputData, attributes: nil)
    }
    
    public static func main() throws {
        try self.main(CommandLine.arguments)
    }
}
