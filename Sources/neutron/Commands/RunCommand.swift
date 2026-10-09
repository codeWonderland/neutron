import ArgumentParser
import Foundation
import NeutronCore

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a Windows program, choosing a graphics backend for it."
    )

    @Argument(help: "Path to the .exe.")
    var program: String

    @Option(name: .shortAndLong, help: "Prefix to run in.")
    var prefix = "default"

    @Option(name: .shortAndLong, help: "Graphics backend: \(BackendChoice.allValueStrings.joined(separator: ", ")).")
    var backend: BackendChoice = .auto

    @Flag(help: "Show the Metal performance HUD.")
    var hud = false

    @Option(help: "WINEDEBUG channels, e.g. +loaddll,err+all.")
    var debug: String?

    @Flag(help: "Print the environment and command instead of running.")
    var dryRun = false

    @Flag(help: "Don't add engine flags such as -force-d3d11 (Unity) or -dx11 (Unreal).")
    var noEngineArgs = false

    @Flag(help: "Don't write a log file (logs/<prefix>/ in Neutron's state folder).")
    var noLog = false

    @Flag(help: "For Unreal games, run the launcher stub instead of its *-Shipping.exe.")
    var launchStub = false

    @Argument(parsing: .postTerminator, help: "Arguments passed to the program (after --).")
    var programArguments: [String] = []

    func run() throws {
        let prefix = try Env.prefixes.get(self.prefix)
        let url = URL(fileURLWithPath: program).standardizedFileURL
        let options = LaunchOptions(backend: backend.backend, hud: hud, debug: debug, engineArguments: !noEngineArgs, launchStub: launchStub)
        let plan = try Env.launcher.gamePlan(prefix: prefix, program: url, arguments: programArguments, options: options)
        for note in plan.notes { print("neutron: \(note)") }
        if dryRun { return printPlan(plan) }
        if let backend = plan.backend { print("neutron: \(url.lastPathComponent) with \(backend.rawValue)") }
        var log: URL?
        if !noLog {
            let file = LaunchLog.url(paths: Env.paths, prefix: prefix.config.name, program: url, date: Date())
            LaunchLog.prune(directory: file.deletingLastPathComponent(), keep: LaunchLog.retained - 1)
            print("neutron: log: \(file.path)")
            log = file
        }
        try execute(plan, log: log)
    }
}

struct DetectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "detect",
        abstract: "Show which graphics APIs a program uses and the backend Neutron would pick."
    )

    @Argument(help: "Path to the .exe.")
    var program: String

    func run() throws {
        let url = URL(fileURLWithPath: program).standardizedFileURL
        let scan = try GameScan(executable: url)
        print("architecture: \(scan.executable.machine)")
        if let engine = scan.engine {
            print("engine: \(engine.engine.description)")
            if engine.renderer != url {
                print("  renderer: \(engine.renderer.path.replacingOccurrences(of: url.deletingLastPathComponent().path + "/", with: ""))")
            }
            print("  D3D12 Agility SDK: \(engine.shipsD3D12AgilitySDK ? "yes" : "no")")
        }
        if scan.executable.machine == .i386 {
            print("  note: 32-bit program; needs a WoW64-capable Wine build")
        }
        let graphics = scan.imports.filter { $0.hasPrefix("d3d") || $0.hasPrefix("dxgi") || $0 == "ddraw.dll" || $0 == "opengl32.dll" || $0 == "vulkan-1.dll" }
        print("graphics imports: \(graphics.isEmpty ? "none" : graphics.sorted().joined(separator: ", "))")
        if scan.usesSteamworks {
            print("steam: uses Steamworks; without the Steam client add steam_appid.txt (the app ID) next to the exe that runs")
        }
        let pick = scan.recommendation
        print("backend: \(pick.backend.rawValue) (\(pick.reason))")
        if let fallback = pick.fallback {
            print("  fallback: \(fallback.rawValue) when no \(pick.backend.requiredRuntime?.rawValue ?? "") runtime is registered or the Wine can't run \(pick.backend.rawValue)")
        }
        if let engine = scan.engine?.engine {
            let flags = engine.arguments(for: pick.fallback ?? pick.backend, userArguments: [])
            if !flags.isEmpty { print("  launch flags on \((pick.fallback ?? pick.backend).rawValue): \(flags.joined(separator: " "))") }
        }
    }
}

struct WineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wine",
        abstract: "Run a raw Wine command in a prefix, e.g. `neutron wine -- winecfg`."
    )

    @Option(name: .shortAndLong, help: "Prefix to run in.")
    var prefix = "default"

    @Flag(help: "Print the environment and command instead of running.")
    var dryRun = false

    @Argument(parsing: .postTerminator, help: "Wine arguments (after --).")
    var arguments: [String] = []

    func run() throws {
        guard !arguments.isEmpty else { throw ValidationError("Give a command after --, e.g. `neutron wine -- winecfg`.") }
        let prefix = try Env.prefixes.get(self.prefix)
        let plan = try Env.launcher.winePlan(prefix: prefix, arguments: arguments, options: LaunchOptions())
        if dryRun { return printPlan(plan) }
        try execute(plan)
    }
}
