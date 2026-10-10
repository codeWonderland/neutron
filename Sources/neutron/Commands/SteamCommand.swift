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
        subcommands: [Run.self, Install.self, Games.self, Launch.self, Import.self],
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

    struct Games: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the games Steam has installed in a prefix.")

        @Option(name: .shortAndLong, help: "Prefix Steam is installed in.")
        var prefix = "steam"

        func run() throws {
            let prefix = try Env.prefixes.get(self.prefix)
            guard SteamClient.isInstalled(in: prefix) else {
                throw ValidationError("Steam isn't installed in '\(self.prefix)'. Run `neutron steam install -p \(self.prefix)`.")
            }
            let steamRoot = SteamClient.executable(in: prefix).deletingLastPathComponent()
            let games = SteamLibrary.games(steamRoot: steamRoot, winePrefix: prefix.winePrefix)
            if games.isEmpty { return print("No games installed yet. Install some from Steam (`neutron steam -p \(self.prefix)`).") }
            for game in games {
                print("\(game.appID)\t\(game.name)\(game.fullyInstalled ? "" : " (not fully installed)")\t\(game.directory.path)")
            }
        }
    }

    struct Launch: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start a game through Steam by app ID (Steam must be signed in).",
            discussion: "The game runs as Steam's child, so it gets Steam's backend (DXMT by default)."
        )

        @Argument(help: "Steam app ID (see `neutron steam games`).")
        var appID: String

        @Option(name: .shortAndLong, help: "Prefix Steam is installed in.")
        var prefix = "steam"

        @Option(help: "Graphics backend.")
        var backend: GraphicsBackend = SteamClient.backend

        @Flag(help: "Print the environment and command instead of running.")
        var dryRun = false

        @Argument(parsing: .postTerminator, help: "Game arguments (after --).")
        var arguments: [String] = []

        func run() throws {
            let prefix = try Env.prefixes.get(self.prefix)
            guard SteamClient.isInstalled(in: prefix) else {
                throw ValidationError("Steam isn't installed in '\(self.prefix)'. Run `neutron steam install -p \(self.prefix)`.")
            }
            let plan = try Env.launcher.steamLaunchGamePlan(prefix: prefix, appID: appID, arguments: arguments,
                                                            options: LaunchOptions(backend: backend))
            if dryRun { return printPlan(plan) }
            _ = try Env.launcher.run(Env.launcher.steamRemoveAutostartPlan(prefix: prefix))
            try execute(plan)
        }
    }

    struct Import: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a local copy of a game to Steam's library instead of downloading it.",
            discussion: """
            Clones the folder (free on APFS) into the prefix's steamapps/common and writes its app \
            manifest. Restart Steam (`neutron steam`) and it verifies the files and fetches only \
            what differs, e.g. a copy taken from another machine's Steam library.
            """
        )

        @Argument(help: "The game's folder (named like its Steam install folder).")
        var folder: String

        @Option(help: "Steam app ID (the number in the store page URL).")
        var appid: String

        @Option(help: "Name to show until Steam fills it in (default: the folder name).")
        var name: String?

        @Option(name: .shortAndLong, help: "Prefix Steam is installed in.")
        var prefix = "steam"

        func run() throws {
            let prefix = try Env.prefixes.get(self.prefix)
            guard SteamClient.isInstalled(in: prefix) else {
                throw ValidationError("Steam isn't installed in '\(self.prefix)'. Run `neutron steam install -p \(self.prefix)`.")
            }
            let steamRoot = SteamClient.executable(in: prefix).deletingLastPathComponent()
            let installed = try SteamLibrary.importGame(from: URL(fileURLWithPath: folder), appID: appid, name: name,
                                                        steamRoot: steamRoot)
            print("Imported to \(installed.path).")
            print("Restart Steam (`neutron kill -p \(self.prefix)`, then `neutron steam -p \(self.prefix)`) to verify and update it.")
        }
    }
}
