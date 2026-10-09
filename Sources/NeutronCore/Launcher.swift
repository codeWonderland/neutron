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
}

public struct LaunchOptions: Sendable {
    /// nil: use the prefix's pinned backend, else auto-detect from the executable.
    public var backend: GraphicsBackend?
    /// Show Apple's Metal performance HUD.
    public var hud = false
    /// WINEDEBUG channels; nil silences Wine's logging.
    public var debug: String?

    public init(backend: GraphicsBackend? = nil, hud: Bool = false, debug: String? = nil) {
        self.backend = backend
        self.hud = hud
        self.debug = debug
    }
}

public struct Launcher: Sendable {
    public let runtimes: RuntimeStore

    public init(runtimes: RuntimeStore) {
        self.runtimes = runtimes
    }

    /// Plan for `wineboot --init`, which populates a new prefix.
    public func initializePlan(prefix: Prefix) throws -> LaunchPlan {
        try winePlan(prefix: prefix, arguments: ["wineboot", "--init"], options: LaunchOptions())
    }

    /// Plan for running a Windows program, picking a graphics backend.
    public func gamePlan(prefix: Prefix, program: URL, arguments: [String] = [],
                         options: LaunchOptions) throws -> LaunchPlan {
        let backend = try options.backend ?? prefix.config.backend ?? GameScan(executable: program).recommendation.backend
        let runtime = try backend.requiredRuntime.map { try runtimes.find($0) }
        let setup = try BackendSetup.make(for: backend, runtime: runtime)

        var plan = try winePlan(prefix: prefix, arguments: [program.path] + arguments, options: options, setup: setup)
        plan.workingDirectory = program.deletingLastPathComponent()
        plan.backend = backend
        return plan
    }

    /// Plan for any Wine command (winecfg, regedit, an installer…) without backend setup.
    public func winePlan(prefix: Prefix, arguments: [String], options: LaunchOptions,
                         setup: BackendSetup = BackendSetup()) throws -> LaunchPlan {
        let wine = try runtimes.find(.wine, version: prefix.config.wineVersion)

        var env: [String: String] = [
            "WINEPREFIX": prefix.winePrefix.path,
            "WINEDEBUG": options.debug ?? "-all",
            // Mach-semaphore sync; ignored by Wine builds without msync.
            "WINEMSYNC": "1",
        ]
        if options.hud { env["MTL_HUD_ENABLED"] = "1" }
        env.merge(setup.environment) { _, new in new }
        if !setup.dllPaths.isEmpty {
            env["WINEDLLPATH"] = setup.dllPaths.map(\.path).joined(separator: ":")
        }

        // The prefix's own settings win, except overrides, which are appended so both apply
        // (Wine lets later entries override earlier ones).
        var custom = prefix.config.environment
        let overrides = [setup.overridesString, custom.removeValue(forKey: "WINEDLLOVERRIDES") ?? ""]
            .filter { !$0.isEmpty }
        if !overrides.isEmpty { env["WINEDLLOVERRIDES"] = overrides.joined(separator: ";") }
        env.merge(custom) { _, new in new }

        return LaunchPlan(executable: wine.wineBinary, arguments: arguments, environment: env,
                          workingDirectory: nil, backend: nil)
    }

    /// Runs the plan in the foreground with inherited stdio and returns Wine's exit status.
    public func run(_ plan: LaunchPlan) throws -> Int32 {
        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(plan.environment) { _, new in new }
        if let directory = plan.workingDirectory { process.currentDirectoryURL = directory }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
