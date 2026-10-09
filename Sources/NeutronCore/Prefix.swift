import Foundation

/// Per-prefix settings, stored next to the Wine prefix as `neutron.json`.
public struct PrefixConfig: Codable, Equatable, Sendable {
    public var name: String
    /// Pinned Wine version; nil uses the newest registered.
    public var wineVersion: String?
    /// Pinned graphics backend; nil auto-detects per executable.
    public var backend: GraphicsBackend?
    /// Extra environment applied on every launch (wins over Neutron's defaults).
    public var environment: [String: String]

    public init(name: String, wineVersion: String? = nil, backend: GraphicsBackend? = nil,
                environment: [String: String] = [:]) {
        self.name = name
        self.wineVersion = wineVersion
        self.backend = backend
        self.environment = environment
    }
}

public struct Prefix: Sendable {
    public var config: PrefixConfig
    /// Neutron's directory for this prefix.
    public let directory: URL

    /// The actual WINEPREFIX.
    public var winePrefix: URL { directory.appendingPathComponent("pfx", isDirectory: true) }
    var configURL: URL { directory.appendingPathComponent("neutron.json") }
}

public struct PrefixStore: Sendable {
    public let paths: NeutronPaths

    public init(paths: NeutronPaths) {
        self.paths = paths
    }

    public func list() throws -> [Prefix] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.prefixes.path) else { return [] }
        return try fm.contentsOfDirectory(atPath: paths.prefixes.path)
            .sorted()
            .compactMap { try? get($0) }
    }

    public func get(_ name: String) throws -> Prefix {
        try validateName(name)
        let directory = paths.prefixes.appendingPathComponent(name, isDirectory: true)
        let configURL = directory.appendingPathComponent("neutron.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw NeutronError.prefixNotFound(name)
        }
        let config = try JSONDecoder().decode(PrefixConfig.self, from: Data(contentsOf: configURL))
        return Prefix(config: config, directory: directory)
    }

    /// Creates the directory and config only; `Launcher.initialize` runs wineboot.
    public func create(_ config: PrefixConfig) throws -> Prefix {
        try validateName(config.name)
        let directory = paths.prefixes.appendingPathComponent(config.name, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            throw NeutronError.prefixExists(config.name)
        }
        let prefix = Prefix(config: config, directory: directory)
        try FileManager.default.createDirectory(at: prefix.winePrefix, withIntermediateDirectories: true)
        try save(prefix)
        return prefix
    }

    public func save(_ prefix: Prefix) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(prefix.config).write(to: prefix.configURL, options: .atomic)
    }

    public func delete(_ name: String) throws {
        let prefix = try get(name)
        try FileManager.default.removeItem(at: prefix.directory)
    }
}
