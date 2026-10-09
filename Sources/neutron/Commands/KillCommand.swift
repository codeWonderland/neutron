import ArgumentParser
import Foundation
import NeutronCore

struct KillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kill",
        abstract: "Stop every Wine process (games, launchers, services) in a prefix."
    )

    @Option(name: .shortAndLong, help: "Prefix to stop.")
    var prefix = "default"

    @Flag(help: "Stop all prefixes.")
    var all = false

    @Flag(help: "Print the environment and command instead of running.")
    var dryRun = false

    func run() throws {
        let prefixes = all ? try Env.prefixes.list() : [try Env.prefixes.get(prefix)]
        for prefix in prefixes {
            let plan = try Env.launcher.killPlan(prefix: prefix)
            if dryRun { printPlan(plan); continue }
            // wineserver -k exits non-zero when no server is running; that's fine here.
            _ = try Env.launcher.run(plan)
            print("Stopped prefix '\(prefix.config.name)'.")
        }
    }
}
