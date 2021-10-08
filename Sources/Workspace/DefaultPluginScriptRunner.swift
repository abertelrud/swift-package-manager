/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
import Foundation
import PackageGraph
import PackageModel
import SPMBuildCore
import TSCBasic
import TSCUtility

/// A plugin script runner that compiles the plugin source files as an executable binary for the host platform, and invokes it as a subprocess.
public struct DefaultPluginScriptRunner: PluginScriptRunner {
    let cacheDir: AbsolutePath
    let toolchain: ToolchainConfiguration
    let enableSandbox: Bool

    private static var _hostTriple = ThreadSafeBox<Triple>()
    private static var _packageDescriptionMinimumDeploymentTarget = ThreadSafeBox<String>()
    private let sdkRootCache = ThreadSafeBox<AbsolutePath>()

    public init(cacheDir: AbsolutePath, toolchain: ToolchainConfiguration, enableSandbox: Bool = true) {
        self.cacheDir = cacheDir
        self.toolchain = toolchain
        self.enableSandbox = enableSandbox
    }

    /// Public protocol function that compiles and runs the plugin as a subprocess.  The tools version controls the availability of APIs in PackagePlugin, and should be set to the tools version of the package that defines the plugin (not of the target to which it is being applied).
    public func runPluginScript(sources: Sources, inputJSON: Data, pluginArguments: [String], toolsVersion: ToolsVersion, writableDirectories: [AbsolutePath], diagnostics: DiagnosticsEngine, fileSystem: FileSystem) throws -> (outputJSON: Data, stdoutText: Data) {
        let compiledExec = try self.compile(sources: sources, toolsVersion: toolsVersion, cacheDir: self.cacheDir)
        return try self.invoke(compiledExec: compiledExec, toolsVersion: toolsVersion, writableDirectories: writableDirectories, input: inputJSON, arguments: pluginArguments)
    }
    
    public var hostTriple: Triple {
        return Self._hostTriple.memoize {
            Triple.getHostTriple(usingSwiftCompiler: self.toolchain.swiftCompilerPath)
        }
    }

    /// Helper function that compiles a plugin script as an executable and returns the path to it.
    fileprivate func compile(sources: Sources, toolsVersion: ToolsVersion, cacheDir: AbsolutePath) throws -> AbsolutePath {
        // FIXME: Much of this is copied from the ManifestLoader and should be consolidated.

        let runtimePath = self.toolchain.swiftPMLibrariesLocation.pluginAPI

        // Compile the package plugin script.
        var command = [self.toolchain.swiftCompilerPath.pathString]

        // FIXME: Workaround for the module cache bug that's been haunting Swift CI
        // <rdar://problem/48443680>
        let moduleCachePath = ProcessEnv.vars["SWIFTPM_MODULECACHE_OVERRIDE"] ?? ProcessEnv.vars["SWIFTPM_TESTS_MODULECACHE"]

        let macOSPackageDescriptionPath: AbsolutePath
        // if runtimePath is set to "PackageFrameworks" that means we could be developing SwiftPM in Xcode
        // which produces a framework for dynamic package products.
        if runtimePath.extension == "framework" {
            command += [
                "-F", runtimePath.parentDirectory.pathString,
                "-framework", "PackagePlugin",
                "-Xlinker", "-rpath", "-Xlinker", runtimePath.parentDirectory.pathString,
            ]
            macOSPackageDescriptionPath = runtimePath.appending(component: "PackagePlugin")
        } else {
            command += [
                "-L", runtimePath.pathString,
                "-lPackagePlugin",
            ]
            #if !os(Windows)
            // -rpath argument is not supported on Windows,
            // so we add runtimePath to PATH when executing the manifest instead
            command += ["-Xlinker", "-rpath", "-Xlinker", runtimePath.pathString]
            #endif

            // note: this is not correct for all platforms, but we only actually use it on macOS.
            macOSPackageDescriptionPath = runtimePath.appending(component: "libPackagePlugin.dylib")
        }

        // Use the same minimum deployment target as the PackageDescription library (with a fallback of 10.15).
        #if os(macOS)
        let triple = self.hostTriple

        let version = try Self._packageDescriptionMinimumDeploymentTarget.memoize {
            (try Self.computeMinimumDeploymentTarget(of: macOSPackageDescriptionPath))?.versionString ?? "10.15"
        }
        command += ["-target", "\(triple.tripleString(forPlatformVersion: version))"]
        #endif

        // Add any extra flags required as indicated by the ManifestLoader.
        command += self.toolchain.swiftCompilerFlags

        command += ["-swift-version", toolsVersion.swiftLanguageVersion.rawValue]
        // if runtimePath is set to "PackageFrameworks" that means we could be developing SwiftPM in Xcode
        // which produces a framework for dynamic package products.
        if runtimePath.extension == "framework" {
            command += ["-I", runtimePath.parentDirectory.parentDirectory.pathString]
        } else {
            command += ["-I", runtimePath.pathString]
        }
        #if os(macOS)
        if let sdkRoot = self.toolchain.sdkRootPath ?? self.sdkRoot() {
            command += ["-sdk", sdkRoot.pathString]
        }
        #endif
        command += ["-package-description-version", toolsVersion.description]
        if let moduleCachePath = moduleCachePath {
            command += ["-module-cache-path", moduleCachePath]
        }
        
        // Parse the plugin as a library so that `@main` is supported even though there might be only a single source file.
        command += ["-parse-as-library"]
        
        command += sources.paths.map { $0.pathString }
        let compiledExec = cacheDir.appending(component: "compiled-plugin")
        command += ["-o", compiledExec.pathString]

        let result = try Process.popen(arguments: command, environment: toolchain.swiftCompilerEnvironment)
        let output = try (result.utf8Output() + result.utf8stderrOutput()).spm_chuzzle() ?? ""
        if result.exitStatus != .terminated(code: 0) {
            // TODO: Make this a proper error.
            throw StringError("failed to compile package plugin:\n\(command)\n\n\(output)")
        }

        return compiledExec
    }

    /// Returns path to the sdk, if possible.
    // FIXME: This is copied from ManifestLoader.  This should be consolidated when ManifestLoader is cleaned up.
    private func sdkRoot() -> AbsolutePath? {
        if let sdkRoot = self.sdkRootCache.get() {
            return sdkRoot
        }

        var sdkRootPath: AbsolutePath?
        // Find SDKROOT on macOS using xcrun.
        #if os(macOS)
        let foundPath = try? Process.checkNonZeroExit(
            args: "/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"
        )
        guard let sdkRoot = foundPath?.spm_chomp(), !sdkRoot.isEmpty else {
            return nil
        }
        let path = AbsolutePath(sdkRoot)
        sdkRootPath = path
        self.sdkRootCache.put(path)
        #endif

        return sdkRootPath
    }

    // FIXME: This is copied from ManifestLoader.  This should be consolidated when ManifestLoader is cleaned up.
    static func computeMinimumDeploymentTarget(of binaryPath: AbsolutePath) throws -> PlatformVersion? {
        let runResult = try Process.popen(arguments: ["/usr/bin/xcrun", "vtool", "-show-build", binaryPath.pathString])
        guard let versionString = try runResult.utf8Output().components(separatedBy: "\n").first(where: { $0.contains("minos") })?.components(separatedBy: " ").last else { return nil }
        return PlatformVersion(versionString)
    }

    fileprivate func invoke(compiledExec: AbsolutePath, toolsVersion: ToolsVersion, writableDirectories: [AbsolutePath], input: Data, arguments: [String]) throws -> (outputJSON: Data, stdoutText: Data) {
        // Construct the command line.  We just pass along any arguments intended for the plugin.
        var command = [compiledExec.pathString] + arguments

        // Write the input data to a file.
        // TODO: In the future this will be a named pipe, so we can talk back and forth.
        // FIXME: Maybe pick a better place for it?
        let pluginInputFilePath = cacheDir.appending(component: ".input.json")
        try localFileSystem.writeFileContents(pluginInputFilePath, data: input)
        
        // Open a file for receiving data from the plugin (removing any previous file).
        // TODO: In the future this will be a named pipe, so we can talk back and forth.
        // FIXME: Maybe pick a better place for it?
        let pluginOutputFilePath = cacheDir.appending(component: ".output.json")
        try? localFileSystem.removeFileTree(pluginOutputFilePath)
        
        // If enabled, run command in a sandbox.
        // This provides some safety against arbitrary code execution when invoking the plugin.
        // We only allow the permissions which are absolutely necessary.
        if self.enableSandbox {
            command = Sandbox.apply(command: command, writableDirectories: writableDirectories + [self.cacheDir])
        }
        print(command.joined(separator: "|"))

        // Invoke the plugin script as a subprocess.
        let environment = [
            "__SWIFTPM_PLUGIN_INPUT_FILE_PATH__": pluginInputFilePath.pathString,
            "__SWIFTPM_PLUGIN_OUTPUT_FILE_PATH__": pluginOutputFilePath.pathString
        ]
        let process = Process(arguments: command, environment: environment, outputRedirection: .collect(redirectStderr: true))
        try process.launch()
        let result = try process.waitUntilExit()
        
        // Any stdout and stderr output from the process is captured and passed along as opaque output, since it
        // presumably contains debug output and/or errors messages that users might want to see.
        let stdoutData = try Data(result.output.get())
        let stdoutText = String(decoding: stdoutData, as: UTF8.self)
        print("\(stdoutText.spm_dropSuffix("\n").split(separator: "\n", omittingEmptySubsequences: false).map({ "🧩 \($0)" }).joined(separator: "\n"))")

        // Read the plugin output. The `PackagePlugin` library writes the output as a PluginEvaluationResult struct
        // encoded as JSON, in the file whose path we passed down in the environment variable.
        let pluginOutputData: Data = try localFileSystem.readFileContents(pluginOutputFilePath)
        
        // Throw an error if we the subprocess ended badly.
        if result.exitStatus != .terminated(code: 0) {
            throw DefaultPluginScriptRunnerError.subprocessFailed("\(result.exitStatus)", command: command, output: stdoutText)
        }
        
        // Otherwise return the JSON data and any output text.
        return (outputJSON: pluginOutputData, stdoutText: stdoutData)
    }
}


/// An error encountered by the default plugin runner.
public enum DefaultPluginScriptRunnerError: Error {
    /// Failed to start running the compiled plugin script as a subprocess.  The message describes the error, and the
    /// command is the full command line that the runner tried to launch.
    case subprocessDidNotStart(_ message: String, command: [String])

    /// Running the compiled plugin script as a subprocess failed.  The message describes the error, the command is
    /// the full command line, and the output contains any emitted stdout and stderr.
    case subprocessFailed(_ message: String, command: [String], output: String)
    
    /// The compiled plugin script completed successfully, but did not emit any JSON output that could be decoded to
    /// transmit plugin information to SwiftPM.  The message describes the problem, the command is the full command
    /// line, and the output contains any emitted stdout and stderr.
    case missingPluginJSON(_ message: String, command: [String], output: String)
}

extension DefaultPluginScriptRunnerError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .subprocessDidNotStart(let message, _):
            return "could not run plugin script: \(message)"
        case .subprocessFailed(let message, _, let output):
            return "running plugin script failed: \(message):\(output.isEmpty ? " (no output)" : "\n" + output)"
        case .missingPluginJSON(let message, _, let output):
            return "plugin script did not emit JSON output: \(message):\(output.isEmpty ? " (no output)" : "\n" + output)"
        }
    }
}
