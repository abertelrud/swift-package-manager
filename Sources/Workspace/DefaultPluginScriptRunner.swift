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
    
    public func compilePluginScript(sources: Sources, toolsVersion: ToolsVersion) throws -> PluginCompilationResult {
        return try self.compile(sources: sources, toolsVersion: toolsVersion, cacheDir: self.cacheDir)
    }

    /// Public protocol function that compiles and runs the plugin as a subprocess.  The tools version controls the availability of APIs in PackagePlugin, and should be set to the tools version of the package that defines the plugin (not of the target to which it is being applied).
    public func runPluginScript(
        sources: Sources,
        input: PluginScriptRunnerInput,
        toolsVersion: ToolsVersion,
        writableDirectories: [AbsolutePath],
        observabilityScope: ObservabilityScope,
        textOutputHandler: @escaping (Data) -> Void,
        handlerQueue: DispatchQueue,
        fileSystem: FileSystem
    ) throws -> PluginScriptRunnerOutput {
        // FIXME: We should only compile the plugin script again if needed.
        let compilationResult = try self.compile(sources: sources, toolsVersion: toolsVersion, cacheDir: self.cacheDir)
        guard let compiledExecutable = compilationResult.compiledExecutable else {
            throw DefaultPluginScriptRunnerError.compilationFailed(compilationResult)
        }
        return try self.invoke(compiledExec: compiledExecutable, writableDirectories: writableDirectories, input: input, textOutputHandler: textOutputHandler, handlerQueue: handlerQueue)
    }

    public var hostTriple: Triple {
        return Self._hostTriple.memoize {
            Triple.getHostTriple(usingSwiftCompiler: self.toolchain.swiftCompilerPath)
        }
    }
    
    /// Helper function that compiles a plugin script as an executable and returns the path of the executable, any emitted diagnostics, etc. This function only throws an error if it wasn't even possible to start compiling the plugin — any regular compilation errors or warnings will be reflected in the returned compilation result.
    fileprivate func compile(sources: Sources, toolsVersion: ToolsVersion, cacheDir: AbsolutePath) throws -> PluginCompilationResult {
        // FIXME: Much of this is copied from the ManifestLoader and should be consolidated.

        // Get access to the path containing the PackagePlugin module and library.
        let runtimePath = self.toolchain.swiftPMLibrariesLocation.pluginAPI

        // We use the toolchain's Swift compiler for compiling the plugin.
        var command = [self.toolchain.swiftCompilerPath.pathString]

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

        // Add the Swift language version implied by the package tools version.
        command += ["-swift-version", toolsVersion.swiftLanguageVersion.rawValue]

        // Add the PackageDescription version specified by the package tools version, which controls what PackagePlugin API is seen.
        command += ["-package-description-version", toolsVersion.description]

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
        
        // Honor any module cache override that's set in the environment.
        let moduleCachePath = ProcessEnv.vars["SWIFTPM_MODULECACHE_OVERRIDE"] ?? ProcessEnv.vars["SWIFTPM_TESTS_MODULECACHE"]
        if let moduleCachePath = moduleCachePath {
            command += ["-module-cache-path", moduleCachePath]
        }

        // Parse the plugin as a library so that `@main` is supported even though there might be only a single source file.
        command += ["-parse-as-library"]
        
        // Add options to create a .dia file containing any diagnostics emitted by the compiler.
        let diagnosticsFile = cacheDir.appending(component: "diagnostics.dia")
        command += ["-Xfrontend", "-serialize-diagnostics-path", "-Xfrontend", diagnosticsFile.pathString]
        
        // Add all the source files that comprise the plugin scripts.
        command += sources.paths.map { $0.pathString }
        
        // Add the path of the compiled executable.
        let executableFile = cacheDir.appending(component: "compiled-plugin")
        command += ["-o", executableFile.pathString]
        
        // Make sure the cache directory in which we'll be placing the compiled executable exists.
        try FileManager.default.createDirectory(at: cacheDir.asURL, withIntermediateDirectories: true, attributes: nil)
        
        // Invoke the compiler and get back the result.
        let compilerResult = try Process.popen(arguments: command, environment: toolchain.swiftCompilerEnvironment)

        // Finally return the result. We return the path of the compiled executable only if the compilation succeeded.
        let compiledExecutable = (compilerResult.exitStatus == .terminated(code: 0)) ? executableFile : nil
        return PluginCompilationResult(compiledExecutable: compiledExecutable, diagnosticsFile: diagnosticsFile, compilerResult: compilerResult)
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
    
    /// Private function that invokes a compiled plugin executable and communicates with it until it finishes.
    fileprivate func invoke(
        compiledExec: AbsolutePath,
        writableDirectories: [AbsolutePath],
        input: PluginScriptRunnerInput,
        textOutputHandler: @escaping (Data) -> Void,
        handlerQueue: DispatchQueue
    ) throws -> PluginScriptRunnerOutput {
        // Construct the command line. Currently we just invoke the executable built from the plugin without any parameters.
        var command = [compiledExec.pathString]

        // Optionally wrap the command in a sandbox, which places some limits on what it can do. In particular, it blocks network access and restricts the paths to which the plugin can make file system changes.
        if self.enableSandbox {
            command = Sandbox.apply(command: command, writableDirectories: writableDirectories + [self.cacheDir])
        }

        // Create and configure a Process. We set the working directory to the cache directory, so that relative paths end up there.
        let process = Process()
        process.executableURL = Foundation.URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.environment = ProcessInfo.processInfo.environment
        process.currentDirectoryURL = self.cacheDir.asURL
        
        // Create a dispatch group for waiting on proces termination and all output from it.
        let waiters = DispatchGroup()
        
        // Set up a pipe for receiving free-form text output from the plugin on its stderr.
        waiters.enter()
        let stderrPipe = Pipe()
        var stderrData = Data()
        func emit(data: Data) {
            handlerQueue.sync { textOutputHandler(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { (fileHandle: FileHandle) -> Void in
            // We just pass the data on to our given output handler.
            let newData = fileHandle.availableData
            if newData.isEmpty {
                fileHandle.readabilityHandler = nil
                waiters.leave()
            }
            else {
                stderrData.append(contentsOf: newData)
                emit(data: newData)
            }
        }
        process.standardError = stderrPipe

        // Set up a pipe for receiving structured messages from the plugin on its stdout.
        let stdoutPipe = Pipe()
        let inputHandle = stdoutPipe.fileHandleForReading
        process.standardOutput = stdoutPipe
        
        // Set up a pipe for sending structured messages to the plugin on its stdin.
        let stdinPipe = Pipe()
        let outputHandle = stdinPipe.fileHandleForWriting
        process.standardInput = stdinPipe

        // Set up a termination handler.
        process.terminationHandler = { _ in
            // We don't do anything special other than note the process exit.
            waiters.leave()
        }

        // Start the plugin process.
        waiters.enter()
        do {
            try process.run()
        } catch {
            throw DefaultPluginScriptRunnerError.subprocessDidNotStart("\(error)", command: command)
        }
        
        /// Send an initial message to the plugin to ask it to perform its action based on the input data.
        try outputHandle.writePluginMessage(.performAction(input: input))
        
        /// Get messages from the plugin. It might tell us it's done or ask us for more information.
        var result: PluginScriptRunnerOutput? = nil
        while let message = try inputHandle.readPluginMessage() {
            switch message {
            case .provideResult(let output):
                // The plugin has completed the action and is providing results.
                result = output
                try outputHandle.writePluginMessage(.quit)
            }
        }
        
        // Wait for the process to terminate and the readers to finish collecting all output.
        waiters.wait()

        // Throw an error if we the subprocess ended badly.
        if !(process.terminationReason == .exit && process.terminationStatus == 0) {
            throw DefaultPluginScriptRunnerError.subprocessFailed("\(process.terminationStatus)", command: command, output: String(decoding: stderrData, as: UTF8.self))
        }
        guard let result = result else {
            throw DefaultPluginScriptRunnerError.missingPluginJSON("didn’t receive output from plugin", command: command, output: String(decoding: stderrData, as: UTF8.self))
        }

        // Otherwise return the result returned by the plugin.
        return result
    }
}

/// The result of compiling a plugin. The executable path will only be present if the compilation succeeds, while the other properties are present in all cases.
public struct PluginCompilationResult {
    /// Path of the compiled executable, or .none if compilation failed.
    public var compiledExecutable: AbsolutePath?
    
    /// Path of the libClang diagnostics file emitted by the compiler (even if compilation succeded, it might contain warnings).
    public  var diagnosticsFile: AbsolutePath
    
    /// Process result of invoking the Swift compiler to produce the executable (contains command line, environment, exit status, and any output).
    public var compilerResult: ProcessResult
}


/// An error encountered by the default plugin runner.
public enum DefaultPluginScriptRunnerError: Error {
    /// Failed to compile the plugin script, so it cannot be run.
    case compilationFailed(PluginCompilationResult)
    
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
        case .compilationFailed(let result):
            return "could not compile plugin script: \(result)"
        case .subprocessDidNotStart(let message, _):
            return "could not run plugin script: \(message)"
        case .subprocessFailed(let message, _, let output):
            return "running plugin script failed: \(message):\(output.isEmpty ? " (no output)" : "\n" + output)"
        case .missingPluginJSON(let message, _, let output):
            return "plugin script did not emit JSON output: \(message):\(output.isEmpty ? " (no output)" : "\n" + output)"
        }
    }
}

/// A message that the host can send to the plugin.
enum HostToPluginMessage: Codable {
    case performAction(input: PluginScriptRunnerInput)
    case quit
}

/// A message that the plugin can send to the host.
enum PluginToHostMessage: Codable {
    case provideResult(output: PluginScriptRunnerOutput)
}

fileprivate extension FileHandle {
    
    func writePluginMessage(_ message: HostToPluginMessage) throws {
        // Encode the message as JSON.
        let payload = try JSONEncoder().encode(message)
        
        // Form the header (a 12-digit length field in base-ten ASCII).
        try self.write(contentsOf: Data(String(format: "%012u", payload.count).utf8))
        
        // The data is the header followed by the payload.
        try self.write(contentsOf: payload)
    }
    
    func readPluginMessage() throws -> PluginToHostMessage? {
        // Read the header (a 12-digit length field in base-ten ASCII).
        guard let header = try self.read(upToCount: 12) else { return nil }
        guard header.count == 12 else {
            throw PluginMessageError.truncatedHeader
        }
        
        // Decode the count.
        guard let count = Int(String(decoding: header, as: UTF8.self)), count >= 2 else {
            throw PluginMessageError.invalidPayloadSize
        }

        // Read the JSON payload.
        guard let payload = try self.read(upToCount: count), payload.count == count else {
            throw PluginMessageError.truncatedPayload
        }

        // Decode and return the message.
        return try JSONDecoder().decode(PluginToHostMessage.self, from: payload)
    }

    enum PluginMessageError: Swift.Error {
        case truncatedHeader
        case invalidPayloadSize
        case truncatedPayload
    }
}
