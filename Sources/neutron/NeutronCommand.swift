import ArgumentParser
import Foundation
import NeutronCore

@main
struct NeutronCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "neutron",
        abstract: "Run Windows games on macOS with Wine, DXMT and D3DMetal.",
        version: "0.1.0",
        subcommands: [RunCommand.self, DetectCommand.self, WineCommand.self, KillCommand.self, DoctorCommand.self,
                      PrefixCommand.self, RuntimeCommand.self]
    )
}

/// Shared stores, so every command uses the same paths.
enum Env {
    static let paths = NeutronPaths.standard()
    static let prefixes = PrefixStore(paths: paths)
    static let runtimes = RuntimeStore(paths: paths)
    static let launcher = Launcher(runtimes: runtimes)
}

extension GraphicsBackend: ExpressibleByArgument {}
extension RuntimeKind: ExpressibleByArgument {}

/// `auto` or a backend name, for options where auto-detection is allowed.
enum BackendChoice: ExpressibleByArgument, CustomStringConvertible {
    case auto
    case fixed(GraphicsBackend)

    init?(argument: String) {
        if argument == "auto" { self = .auto; return }
        guard let backend = GraphicsBackend(rawValue: argument) else { return nil }
        self = .fixed(backend)
    }

    static var allValueStrings: [String] { ["auto"] + GraphicsBackend.allCases.map(\.rawValue) }

    var backend: GraphicsBackend? {
        if case .fixed(let backend) = self { return backend }
        return nil
    }

    var description: String { backend?.rawValue ?? "auto" }
}

func printPlan(_ plan: LaunchPlan) {
    if let composition = plan.composition {
        let state = composition.isBuilt ? "built" : "built on first run"
        print("# wine \(composition.wine.version) + \(composition.backend.kind.rawValue) \(composition.backend.version) (\(state)): \(composition.path.path)")
    }
    for (key, value) in plan.environment.sorted(by: { $0.key < $1.key }) {
        print("\(key)=\(value)")
    }
    if let scan = plan.gstreamerScan { print("\(scan.path) --version   # updates the GStreamer plugin registry") }
    if let directory = plan.workingDirectory { print("cd \(directory.path)") }
    print(([plan.executable.path] + plan.arguments).joined(separator: " "))
}

func execute(_ plan: LaunchPlan, log: URL? = nil) throws {
    fflush(stdout)  // so our messages come before Wine's output when piped
    let status = try Env.launcher.run(plan, log: log)
    if status != 0 { throw ExitCode(status) }
}
