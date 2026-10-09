import ArgumentParser
import Foundation
import NeutronCore

struct RuntimeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runtime",
        abstract: "Register Wine, DXMT and Game Porting Toolkit builds.",
        subcommands: [Add.self, List.self, Remove.self]
    )

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Register a runtime that's already on disk.",
            discussion: """
            wine: a Wine build root containing bin/wine (or a Wine .app bundle).
            dxmt: an extracted DXMT release containing x86_64-windows/d3d11.dll.
            gptk: Apple's Game Porting Toolkit folder; Neutron finds redist/lib inside it.
            """
        )

        @Argument(help: "Runtime kind: \(RuntimeKind.allCases.map(\.rawValue).joined(separator: ", ")).")
        var kind: RuntimeKind

        @Argument(help: "Path to the runtime.")
        var path: String

        @Option(help: "Version label (default: the folder name).")
        var version: String?

        func run() throws {
            let runtime = try Env.runtimes.add(kind: kind, path: URL(fileURLWithPath: path), version: version)
            print("Registered \(kind.rawValue) \(runtime.version) at \(runtime.path.path)")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List registered runtimes.")

        func run() throws {
            let runtimes = try Env.runtimes.list()
            if runtimes.isEmpty { return print("No runtimes. Add one with `neutron runtime add wine <path>`.") }
            for runtime in runtimes.sorted(by: { ($0.kind.rawValue, $0.version) < ($1.kind.rawValue, $1.version) }) {
                print("\(runtime.kind.rawValue)  \(runtime.version)  \(runtime.path.path)")
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Unregister a runtime (files are left on disk).")

        @Argument var kind: RuntimeKind
        @Argument var version: String

        func run() throws {
            try Env.runtimes.remove(kind: kind, version: version)
            print("Removed \(kind.rawValue) \(version).")
        }
    }
}
