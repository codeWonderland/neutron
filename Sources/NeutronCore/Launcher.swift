import Foundation

/// A fully-resolved Wine invocation. Building it is separate from running it so it can be
/// printed (`--dry-run`) and tested.
public struct LaunchPlan: Sendable {
    public var executable: URL
    public var arguments: [String]
    /// Only the variables Neutron sets; merged over the inherited environment at launch.
    public var environment: [String: String]
    public var workingDirectory: URL?
    public var backend: GraphicsBackend?
    /// Built (if needed) by `Launcher.run`; `executable` is already inside it.
    public var composition: ComposedRuntime?
    public var prefixName: String
    public var winePrefix: URL
    /// Why the plan looks the way it does (backend fallback, engine flags), for the CLI to show.
    public var notes: [String] = []
}

public struct LaunchOptions: Sendable {
    /// nil: use the prefix's pinned backend, else auto-detect from the executable.
    public var backend: GraphicsBackend?
    /// Show Apple's Metal performance HUD.
    public var hud = false
    /// WINEDEBUG channels; nil silences Wine's logging.
    public var debug: String?
    /// Add the engine's force-D3D11 flag when the backend has no D3D12 (Unity, Unreal).
    public var engineArguments = true
    /// Run an Unreal stub launcher itself instead of the `*-Shipping.exe` it starts.
    public var launchStub = false

    public init(backend: GraphicsBackend? = nil, hud: Bool = false, debug: String? = nil, engineArguments: Bool = true,
                launchStub: Bool = false) {
        self.launchStub = launchStub
        self.backend = backend
        self.hud = hud
        self.debug = debug
        self.engineArguments = engineArguments
    }
}

public struct Launcher: Sendable {
    public let runtimes: RuntimeStore

    /// How to read a Wine build's capabilities; replaceable in tests.
    var capabilities: @Sendable (Runtime) -> WineCapabilities = { WineCapabilities(wine: $0) }

    public init(runtimes: RuntimeStore) {
        self.runtimes = runtimes
    }

    /// Plan for `wineboot --init`, which populates a new prefix.
    public func initializePlan(prefix: Prefix) throws -> LaunchPlan {
        try winePlan(prefix: prefix, arguments: ["wineboot", "--init"], options: LaunchOptions())
    }

    /// Plan for `wineserver -k`, which ends every Wine process in the prefix. It uses the
    /// prefix's own build and environment: some builds (e.g. CrossOver engines) run their
    /// processes from temporary copies that `pkill wineserver` doesn't catch.
    public func killPlan(prefix: Prefix) throws -> LaunchPlan {
        var plan = try winePlan(prefix: prefix, arguments: ["-k"], options: LaunchOptions())
        plan.executable = plan.executable.deletingLastPathComponent().appendingPathComponent("wineserver")
        return plan
    }

    /// Plan for running a Windows program, picking a graphics backend.
    public func gamePlan(prefix: Prefix, program: URL, arguments: [String] = [],
                         options: LaunchOptions) throws -> LaunchPlan {
        var notes: [String] = []
        let chosen = options.backend ?? prefix.config.backend
        // Engine flags apply to explicit backends too, so scan whenever the file is readable.
        let scan = chosen == nil ? try GameScan(executable: program) : try? GameScan(executable: program)
        var backend = chosen ?? scan!.recommendation.backend
        let wine = try runtimes.find(.wine, version: prefix.config.wineVersion)
        let capabilities = self.capabilities(wine)
        if chosen == nil, let fallback = scan?.recommendation.fallback,
           isAvailable(fallback), capabilities.supports(fallback) {
            if !isAvailable(backend) {
                notes.append("no \(backend.requiredRuntime?.rawValue ?? backend.rawValue) runtime registered; using \(fallback.rawValue) instead of \(backend.rawValue)")
                backend = fallback
            } else if let problem = capabilities.problem(with: backend) {
                notes.append("using \(fallback.rawValue) instead of \(backend.rawValue): wine \(wine.version) can't run \(backend.rawValue); \(problem)")
                backend = fallback
            }
        }
        if let problem = capabilities.problem(with: backend) {
            notes.append("warning: wine \(wine.version) probably can't run \(backend.rawValue): \(problem)")
        }
        let runtime = try backend.requiredRuntime.map { try runtimes.find($0) }
        let setup = try BackendSetup.make(for: backend, runtime: runtime)

        var engineArguments: [String] = []
        if options.engineArguments, let engine = scan?.engine?.engine {
            engineArguments = engine.arguments(for: backend, userArguments: arguments)
            if !engineArguments.isEmpty {
                notes.append("\(engine.description) on \(backend.rawValue): adding \(engineArguments.joined(separator: " ")) (disable with --no-engine-args)")
            }
        }

        // An Unreal stub only checks for the VC++ runtime and relaunches the Shipping exe. Its
        // check fails on CrossOver-based Wine even with Microsoft's runtime installed, so run
        // the Shipping exe directly (it finds its project without the stub's arguments).
        var target = program
        var projectArgument: [String] = []
        if !options.launchStub, let engine = scan?.engine, case .unreal = engine.engine, engine.renderer != program {
            target = engine.renderer
            // The stub passes the project name first; do the same.
            projectArgument = engine.unrealProject.map { [$0] } ?? []
            notes.append("Unreal launcher stub: running \(([target.lastPathComponent] + projectArgument).joined(separator: " ")) directly (--launch-stub to run the stub)")
        }

        let appID = target.deletingLastPathComponent().appendingPathComponent("steam_appid.txt")
        if scan?.usesSteamworks == true, !FileManager.default.fileExists(atPath: appID.path) {
            notes.append("uses Steamworks but has no steam_appid.txt; without the Steam client it may quit or relaunch through Steam. Put the game's Steam app ID in \(appID.path)")
        }

        var plan = try winePlan(prefix: prefix, arguments: [target.path] + projectArgument + engineArguments + arguments,
                                options: options, setup: setup)
        plan.workingDirectory = target.deletingLastPathComponent()
        plan.backend = backend
        plan.notes = notes
        return plan
    }

    private func isAvailable(_ backend: GraphicsBackend) -> Bool {
        guard let kind = backend.requiredRuntime else { return true }
        return (try? runtimes.find(kind)) != nil
    }

    /// Plan for any Wine command (winecfg, regedit, an installer…) without backend setup.
    public func winePlan(prefix: Prefix, arguments: [String], options: LaunchOptions,
                         setup: BackendSetup = BackendSetup()) throws -> LaunchPlan {
        let wine = try runtimes.find(.wine, version: prefix.config.wineVersion)
        let composition = setup.overlay.map { ComposedRuntime(wine: wine, backend: $0, paths: runtimes.paths) }

        var env: [String: String] = [
            "WINEPREFIX": prefix.winePrefix.path,
            "WINEDEBUG": options.debug ?? "-all",
            // Mach-semaphore sync; ignored by Wine builds without msync.
            "WINEMSYNC": "1",
            // MoltenVK (used by winevulkan) logs info to stdout by default; errors only.
            "MVK_CONFIG_LOG_LEVEL": "1",
        ]
        if options.hud { env["MTL_HUD_ENABLED"] = "1" }
        var libraries = wine.libraryPaths ?? []
        if let gstreamer = wine.gstreamer {
            // winegstreamer.so links @rpath/libgst*.dylib and finds them on the fallback path.
            // The plugin registry is cached per Wine runtime under Neutron's state. GStreamer
            // builds it by loading every plugin, so do that in its scanner process when the
            // install has one: in the game's process, plugins like vulkan bring a second
            // MoltenVK alongside Wine's.
            libraries.append(gstreamer.appendingPathComponent("lib"))
            env["GST_PLUGIN_SYSTEM_PATH_1_0"] = gstreamer.appendingPathComponent("lib/gstreamer-1.0").path
            env["GST_REGISTRY_1_0"] = runtimes.paths.gstreamerRegistry(wineVersion: wine.version).path
            let scanner = gstreamer.appendingPathComponent("libexec/gstreamer-1.0/gst-plugin-scanner")
            if FileManager.default.isExecutableFile(atPath: scanner.path) {
                env["GST_PLUGIN_SCANNER_1_0"] = scanner.path
            } else {
                env["GST_REGISTRY_FORK"] = "no"
            }
        }
        if !libraries.isEmpty {
            env["DYLD_FALLBACK_LIBRARY_PATH"] = libraries.map(\.path).joined(separator: ":")
        }
        env.merge(setup.environment) { _, new in new }

        // The prefix's own settings win, except overrides, which are appended so both apply
        // (Wine lets later entries override earlier ones).
        var custom = prefix.config.environment
        let overrides = [setup.overridesString, custom.removeValue(forKey: "WINEDLLOVERRIDES") ?? ""]
            .filter { !$0.isEmpty }
        if !overrides.isEmpty { env["WINEDLLOVERRIDES"] = overrides.joined(separator: ";") }
        env.merge(custom) { _, new in new }

        return LaunchPlan(executable: composition?.wineBinary ?? wine.wineBinary, arguments: arguments,
                          environment: env, workingDirectory: nil, backend: nil, composition: composition,
                          prefixName: prefix.config.name, winePrefix: prefix.winePrefix)
    }

    /// Runs the plan in the foreground and returns Wine's exit status. First builds the
    /// composed runtime and installs the backend's DLLs into the prefix. With `log`, output
    /// goes to that file (see `LaunchLog`) and is echoed to stderr; otherwise stdio is inherited.
    public func run(_ plan: LaunchPlan, log: URL? = nil) throws -> Int32 {
        if let composition = plan.composition {
            try composition.build()
            if !composition.missingPrefixDLLs(winePrefix: plan.winePrefix).isEmpty {
                var update = plan
                update.arguments = ["wineboot", "-u"]
                update.workingDirectory = nil
                update.composition = nil
                _ = try run(update, log: log)
                let missing = composition.missingPrefixDLLs(winePrefix: plan.winePrefix)
                if !missing.isEmpty {
                    throw NeutronError.prefixMissingBackendDLLs(prefix: plan.prefixName, runtime: composition.backend.kind, files: missing)
                }
            }
        }

        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(plan.environment) { _, new in new }
        if let directory = plan.workingDirectory { process.currentDirectoryURL = directory }
        guard let log else {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        let fm = FileManager.default
        try fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil) }
        let writer = try FileHandle(forWritingTo: log)
        defer { try? writer.close() }
        writer.seekToEndOfFile()
        writer.write(Data(LaunchLog.header(for: plan, date: Date()).utf8))
        let reader = try FileHandle(forReadingFrom: log)
        defer { try? reader.close() }
        reader.seekToEndOfFile()

        process.standardOutput = writer
        process.standardError = writer
        try process.run()
        let echo = { FileHandle.standardError.write(reader.readDataToEndOfFile()) }
        while process.isRunning {
            echo()
            usleep(100_000)
        }
        echo()
        return process.terminationStatus
    }
}
