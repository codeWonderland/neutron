import ArgumentParser
import Foundation
import NeutronCore

struct PrefixCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prefix",
        abstract: "Manage Wine prefixes (bottles).",
        subcommands: [Create.self, List.self, Delete.self, SetBackend.self, SetEnv.self]
    )

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create and initialize a prefix.")

        @Argument(help: "Prefix name.")
        var name = "default"

        @Option(help: "Pin a Wine version (default: newest registered).")
        var wine: String?

        @Option(help: "Pin a graphics backend (default: auto).")
        var backend: BackendChoice = .auto

        @Flag(help: "Skip running wineboot.")
        var noInit = false

        func run() throws {
            if let wine { _ = try Env.runtimes.find(.wine, version: wine) }
            let prefix = try Env.prefixes.create(PrefixConfig(name: name, wineVersion: wine, backend: backend.backend))
            print("Created prefix '\(name)' at \(prefix.winePrefix.path)")
            guard !noInit else { return }
            print("Initializing with wineboot (takes a minute the first time)…")
            try execute(Env.launcher.initializePlan(prefix: prefix))
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List prefixes.")

        func run() throws {
            let prefixes = try Env.prefixes.list()
            if prefixes.isEmpty { return print("No prefixes. Create one with `neutron prefix create`.") }
            for prefix in prefixes {
                let config = prefix.config
                print("\(config.name)  wine=\(config.wineVersion ?? "newest")  backend=\(config.backend?.rawValue ?? "auto")")
            }
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a prefix and everything installed in it.")

        @Argument(help: "Prefix name.")
        var name: String

        @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
        var yes = false

        func run() throws {
            let prefix = try Env.prefixes.get(name)
            if !yes {
                print("Delete \(prefix.directory.path) and all games installed in it? [y/N] ", terminator: "")
                guard readLine()?.lowercased() == "y" else { return print("Cancelled.") }
            }
            try Env.prefixes.delete(name)
            print("Deleted prefix '\(name)'.")
        }
    }

    struct SetBackend: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set-backend", abstract: "Pin a prefix's graphics backend, or `auto`.")

        @Argument(help: "Prefix name.")
        var name: String

        @Argument(help: "Backend: \(BackendChoice.allValueStrings.joined(separator: ", ")).")
        var backend: BackendChoice

        func run() throws {
            var prefix = try Env.prefixes.get(name)
            prefix.config.backend = backend.backend
            try Env.prefixes.save(prefix)
            print("Prefix '\(name)' backend: \(backend)")
        }
    }

    struct SetEnv: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set-env", abstract: "Set (KEY=VALUE) or unset (KEY=) a prefix environment variable.")

        @Argument(help: "Prefix name.")
        var name: String

        @Argument(help: "KEY=VALUE, or KEY= to remove.")
        var assignment: String

        func run() throws {
            guard let eq = assignment.firstIndex(of: "="), eq != assignment.startIndex else {
                throw ValidationError("Expected KEY=VALUE.")
            }
            let key = String(assignment[..<eq])
            let value = String(assignment[assignment.index(after: eq)...])
            var prefix = try Env.prefixes.get(name)
            prefix.config.environment[key] = value.isEmpty ? nil : value
            try Env.prefixes.save(prefix)
            print(value.isEmpty ? "Removed \(key)." : "Set \(key)=\(value).")
        }
    }
}
