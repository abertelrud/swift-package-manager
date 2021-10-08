/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

@_implementationOnly import Foundation

/// Provides information about the package for which the plugin is invoked,
/// as well as contextual information based on the plugin's stated intent
/// and requirements.
public struct PluginContext {
    /// Information about the package to which the plugin is being applied.
    public let package: Package

    /// The path of a writable directory into which the plugin or the build
    /// commands it constructs can write anything it wants. This could include
    /// any generated source files that should be processed further, and it
    /// could include any caches used by the build tool or the plugin itself.
    /// The plugin is in complete control of what is written under this di-
    /// rectory, and the contents are preserved between builds.
    ///
    /// A plugin would usually create a separate subdirectory of this directory
    /// for each command it creates, and the command would be configured to
    /// write its outputs to that directory. The plugin may also create other
    /// directories for cache files and other file system content that either
    /// it or the command will need.
    public let pluginWorkDirectory: Path

    /// The path of the directory into which built products associated with
    /// targets in the graph are written. This is a private implementation
    /// detail.
    let builtProductsDirectory: Path

    /// Looks up and returns the path of a named command line executable tool.
    /// The executable must be provided by an executable target or a binary
    /// target on which the package plugin target depends. This function throws
    /// an error if the tool cannot be found. The lookup is case sensitive.
    public func tool(named name: String) throws -> Tool {
        if let path = self.toolNamesToPaths[name] { return Tool(name: name, path: path) }
        throw PluginContextError.toolNotFound(name: name)
    }

    /// A mapping from tool names to their definitions. Not directly available
    /// to the plugin, but used by the `tool(named:)` API.
    let toolNamesToPaths: [String: Path]
    
    /// Information about a particular tool that is available to a plugin.
    public struct Tool {
        /// Name of the tool (suitable for display purposes).
        public let name: String

        /// Full path of the built or provided tool in the file system.
        public let path: Path
    }
    
    var targetNamesToEncodedBuildInfos: [String: String]?
    
    /// Invokes the named tool in the Swift toolchain and returns its output.
    // FIXME: This should be unified with the `tool(named:)` above so that either custom tools or toolchain tools can be accessed.
    public func invokeToolchainCommand(named name: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [name] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
    
    struct TargetBuildInfo: Decodable {
        var symbolGraphDirPath: String
    }
    
    /// Private function to return the build info associated with a target with
    /// a given name. Getting this up-front is temporary; in the future we will
    /// talk back to SwiftPM and ask it to return the requested information.
    func buildInfo(for target: Target) throws -> TargetBuildInfo? {
        guard let jsonString = self.targetNamesToEncodedBuildInfos?[target.name] else { return nil }
        return try JSONDecoder().decode(TargetBuildInfo.self, from: Data(jsonString.utf8))
    }
    
    /// Return the directory containing symbol graph files for the given target
    /// and options. If the symbol graphs need to be created or updated first,
    /// they will be.
    ///
    /// In the future this would talk back to SwiftPM and ask it to return the
    /// requested information.
    public func getSymbolGraphDirectory(for target: Target, options: SymbolGraphOptions) throws -> Path {
        guard let path = try self.buildInfo(for: target)?.symbolGraphDirPath else {
            throw PluginContextError.buildInfoNotFound(targetName: target.name)
        }
        return Path(path)
    }
    
    public struct SymbolGraphOptions {
        public var minimumAccessLevel: AccessLevel = AccessLevel.public

        public enum AccessLevel: String, RawRepresentable, CaseIterable {
            case `private`, `fileprivate`, `internal`, `public`, `open`
        }
        
        public init(minimumAccessLevel: AccessLevel) {
            self.minimumAccessLevel = minimumAccessLevel
        }
    }
}



/// Provides information about the target being built, as well as contextual
/// information such as the paths of the directories to which commands should
/// be configured to write their outputs. This information should be used as
/// part of generating the commands to be run during the build.
public struct TargetBuildContext {
    /// The name of the target being built, as specified in the manifest.
    public let targetName: String

    /// The module name of the target. This is currently derived from the name,
    /// but could be customizable in the package manifest in a future SwiftPM
    /// version.
    public let moduleName: String

    /// The path of the target source directory.
    public let targetDirectory: Path

    /// That path of the package that contains the target.
    public let packageDirectory: Path

    /// Information about the input files specified in the target being built,
    /// including the sources, resources, and other files. This sequence also
    /// includes any source files generated by other plugins that are listed
    /// earlier than this plugin in the `plugins` parameter of the target
    /// being built.
    public let inputFiles: FileList

    /// Information about all targets in the dependency closure of the target
    /// to which the plugin is being applied. This list is in topologically
    /// sorted order, with immediate dependencies appearing earlier and more
    /// distant dependencies later in the list. This is mainly intended for
    /// generating lists of search path arguments, etc.
    public let dependencies: [DependencyTargetInfo]

    /// Provides information about a target that appears in the dependency
    /// closure of the target to which the plugin is being applied.
    public struct DependencyTargetInfo: Decodable {

        /// The name of the target.
        public let targetName: String

        /// The module name of the target. This is currently derived from the
        /// name, but could be customizable in the package manifest in a future
        /// SwiftPM version.
        public let moduleName: String

        /// Path of the target source directory.
        public let targetDirectory: Path

        /// Path of the public headers directory, if any (Clang targets only).
        public let publicHeadersDirectory: Path?
    }

    /// The path of a writable directory into which the plugin or the build
    /// commands it constructs can write anything it wants. This could include
    /// any generated source files that should be processed further, and it
    /// could include any caches used by the build tool or the plugin itself.
    /// The plugin is in complete control of what is written under this di-
    /// rectory, and the contents are preserved between builds.
    ///
    /// A plugin would usually create a separate subdirectory of this directory
    /// for each command it creates, and the command would be configured to
    /// write its outputs to that directory. The plugin may also create other
    /// directories for cache files and other file system content that either
    /// it or the command will need.
    public let pluginWorkDirectory: Path

    /// The path of the directory into which built products associated with
    /// the target are written.
    public let builtProductsDirectory: Path

    /// Looks up and returns the path of a named command line executable tool.
    /// The executable must be provided by an executable target or a binary
    /// target on which the package plugin target depends. This function throws
    /// an error if the tool cannot be found. The lookup is case sensitive.
    public func tool(named name: String) throws -> ToolInfo {
        if let path = self.toolNamesToPaths[name] { return ToolInfo(name: name, path: path) }
        throw PluginContextError.toolNotFound(name: name)
    }

    /// A mapping from tool names to their definitions. Not directly available
    /// to the plugin, but used by the `tool(named:)` API.
    let toolNamesToPaths: [String: Path]
    
    /// Information about a particular tool that is available to a plugin.
    public struct ToolInfo {
        /// Name of the tool (suitable for display purposes).
        public let name: String

        /// Full path of the built or provided tool in the file system.
        public let path: Path
    }
}
