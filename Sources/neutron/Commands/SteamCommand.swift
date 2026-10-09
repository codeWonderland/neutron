import ArgumentParser
import Foundation
import NeutronCore

struct SteamCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "steam",
        abstract: "Install and run Steam for Windows in a prefix.",
        discussion: """
        Steam's UI needs DXMT and a Wine built with tools/wine-dxmt plus a DXMT built with \
        tools/dxmt-patch (cross-process presentation); with other builds its window stays black.
        """,
        subcommands: [Run.self, Install.self],
        defaultSubcommand: Run.self
    )

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download Steam's installer and install it.")

        @Option(name: .shortAndLong, help: "Prefix to install into (created if missing).")
        var prefix = "steam"

        @Option(help: "Use this SteamSetup.exe instead of downloading it.")
        var installer: String?

        func run() throws {
            let prefix: Prefix
            if let existing = try? Env.prefixes.get(self.prefix) {
                prefix = existing
            } else {
                prefix = try Env.prefixes.create(PrefixConfig(name: self.prefix))
                print("Created prefix '\(self.prefix)'; initializing with wineboot…")
                try execute(Env.launcher.initializePlan(prefix: prefix))
            }

            let setup: URL
            if let installer {
                setup = URL(fileURLWithPath: installer)
            } else {
                setup = Env.paths.root.appendingPathComponent("downloads/SteamSetup.exe")
                print("Downloading \(SteamClient.installerURL.absoluteString)…")
                let data = try Data(contentsOf: SteamClient.installerURL)
                try FileManager.default.createDirectory(at: setup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: setup)
            }
            print("Installing Steam into '\(self.prefix)'…")
            try execute(Env.launcher.steamInstallPlan(prefix: prefix, installer: setup))
            guard SteamClient.isInstalled(in: prefix) else {
                throw ValidationError("Steam's installer finished but \(SteamClient.executable(in: prefix).path) is missing.")
            }
            _ = try Env.launcher.run(Env.launcher.steamRemoveAutostartPlan(prefix: prefix))
            print("""
            Installed. Start it with `neutron steam -p \(self.prefix)`; the first run downloads the client \
            (about 1.4 GB) and restarts itself.
            """)
        }
    }

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start the Steam client (default).")

        @Option(name: .shortAndLong, help: "Prefix Steam is installed in.")
        var prefix = "steam"

        @Option(help: "Graphics backend for Steam's UI.")
        var backend: GraphicsBackend = SteamClient.backend

        @Option(help: "WINEDEBUG channels, e.g. +seh,+loaddll.")
        var debug: String?

        @Flag(help: "Print the environment and command instead of running.")
        var dryRun = false

        @Argument(parsing: .postTerminator, help: "Extra Steam arguments (after --).")
        var arguments: [String] = []

        func run() throws {
            let prefix = try Env.prefixes.get(self.prefix)
            guard SteamClient.isInstalled(in: prefix) else {
                throw ValidationError("Steam isn't installed in '\(self.prefix)'. Run `neutron steam install -p \(self.prefix)`.")
            }
            let plan = try Env.launcher.steamClientPlan(prefix: prefix, arguments: arguments,
                                                        options: LaunchOptions(backend: backend, debug: debug))
            for note in plan.notes { print("neutron: \(note)") }
            if dryRun { return printPlan(plan) }
            // Steam re-adds its autostart value; remove it so `wineboot` never starts a copy without DXMT.
            _ = try Env.launcher.run(Env.launcher.steamRemoveAutostartPlan(prefix: prefix))
            let log = LaunchLog.url(paths: Env.paths, prefix: self.prefix, program: SteamClient.executable(in: prefix), date: Date())
            LaunchLog.prune(directory: log.deletingLastPathComponent(), keep: LaunchLog.retained - 1)
            print("neutron: log: \(log.path)")
            try execute(plan, log: log)
        }
    }
}
