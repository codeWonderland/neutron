import Foundation

/// Where Neutron keeps its state. Override the root with `NEUTRON_HOME`.
public struct NeutronPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func standard() -> NeutronPaths {
        if let override = ProcessInfo.processInfo.environment["NEUTRON_HOME"], !override.isEmpty {
            return NeutronPaths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return NeutronPaths(root: support.appendingPathComponent("Neutron", isDirectory: true))
    }

    public var prefixes: URL { root.appendingPathComponent("prefixes", isDirectory: true) }
    public var runtimes: URL { root.appendingPathComponent("runtimes", isDirectory: true) }
    public var runtimeManifest: URL { runtimes.appendingPathComponent("manifest.json") }
}
