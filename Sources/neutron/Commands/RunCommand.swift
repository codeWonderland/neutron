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

    @Argument(parsing: .postTerminator, help: "Arguments passed to the program (after --).")
    var programArguments: [String] = []

    func run() throws {
        let prefix = try Env.prefixes.get(self.prefix)
        let url = URL(fileURLWithPath: program).standardizedFileURL
        let options = LaunchOptions(backend: backend.backend, hud: hud, debug: debug)
        let plan = try Env.launcher.gamePlan(prefix: prefix, program: url, arguments: programArguments, options: options)
        if dryRun { return printPlan(plan) }
        if let backend = plan.backend { print("neutron: \(url.lastPathComponent) with \(backend.rawValue)") }
        try execute(plan)
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
        let scan = try GameScan(executable: URL(fileURLWithPath: program).standardizedFileURL)
        print("architecture: \(scan.executable.machine)")
        if scan.executable.machine == .i386 {
            print("  note: 32-bit program; needs a WoW64-capable Wine build")
        }
        let graphics = scan.imports.filter { $0.hasPrefix("d3d") || $0.hasPrefix("dxgi") || $0 == "ddraw.dll" || $0 == "opengl32.dll" || $0 == "vulkan-1.dll" }
        print("graphics imports: \(graphics.isEmpty ? "none" : graphics.sorted().joined(separator: ", "))")
        print("backend: \(scan.recommendation.backend.rawValue) (\(scan.recommendation.reason))")
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
