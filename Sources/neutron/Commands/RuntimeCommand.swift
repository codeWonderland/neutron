import ArgumentParser
import Foundation
import NeutronCore

struct RuntimeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runtime",
        abstract: "Register Wine, DXMT and Game Porting Toolkit builds.",
        subcommands: [Add.self, List.self, Remove.self, SetGStreamer.self]
    )

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Register a runtime that's already on disk.",
            discussion: """
            wine: a Wine build root containing bin/wine (or a Wine .app bundle).
              DXMT needs a Wine whose winemac.so exports macdrv_functions; patch a stock
              build with tools/wine-dxmt/build.sh, or use a CrossOver-based build.
            dxmt: an extracted DXMT release containing x86_64-windows/d3d11.dll.
            gptk: Apple's Game Porting Toolkit folder; Neutron finds redist/lib inside it.
            """
        )

        @Argument(help: "Runtime kind: \(RuntimeKind.allCases.map(\.rawValue).joined(separator: ", ")).")
        var kind: RuntimeKind

        @Argument(help: "Path to the runtime.")
        var path: String

        @Option(help: "Version label (default: the folder name, or an app bundle's name and version).")
        var version: String?

        @Option(name: .customLong("library-path"), help: "Folder of dylibs the Wine build needs from its host app (repeatable).")
        var libraryPaths: [String] = []

        @Option(help: "GStreamer install for in-game video (e.g. /Library/Frameworks/GStreamer.framework).")
        var gstreamer: String?

        func run() throws {
            let runtime = try Env.runtimes.add(kind: kind, path: URL(fileURLWithPath: path), version: version,
                                               libraryPaths: libraryPaths.map { URL(fileURLWithPath: $0) },
                                               gstreamer: gstreamer.map { URL(fileURLWithPath: $0) })
            print("Registered \(kind.rawValue) \(runtime.version) at \(runtime.path.path)")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List registered runtimes.")

        func run() throws {
            let runtimes = try Env.runtimes.list()
            if runtimes.isEmpty { return print("No runtimes. Add one with `neutron runtime add wine <path>`.") }
            for runtime in runtimes.sorted(by: { ($0.kind.rawValue, $0.version) < ($1.kind.rawValue, $1.version) }) {
                print("\(runtime.kind.rawValue)  \(runtime.version)  \(runtime.path.path)"
                      + (runtime.gstreamer.map { "  (GStreamer: \($0.path))" } ?? ""))
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

    struct SetGStreamer: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-gstreamer",
            abstract: "Set the GStreamer install a registered Wine uses for in-game video, or `none`."
        )

        @Argument(help: "The Wine runtime's version label (see `neutron runtime list`).")
        var version: String

        @Argument(help: "A GStreamer install, e.g. /Library/Frameworks/GStreamer.framework, or `none`.")
        var path: String

        func run() throws {
            let runtime = try Env.runtimes.setGStreamer(wineVersion: version,
                                                        gstreamer: path == "none" ? nil : URL(fileURLWithPath: path))
            print(runtime.gstreamer.map { "wine \(version) uses GStreamer at \($0.path)." } ?? "wine \(version) has no GStreamer.")
        }
    }
}
