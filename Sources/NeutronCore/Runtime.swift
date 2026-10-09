import Foundation

public enum RuntimeKind: String, Codable, CaseIterable, Sendable {
    /// A Wine build (needs `bin/wine` or `bin/wine64`).
    case wine
    /// DXMT: D3D10/11 → Metal. https://github.com/3Shain/dxmt
    case dxmt
    /// Apple's Game Porting Toolkit redist (D3DMetal). Users supply their own copy.
    case gptk
}

/// A registered runtime. `path` is the resolved root that the layout helpers below rely on.
public struct Runtime: Codable, Equatable, Sendable {
    public let kind: RuntimeKind
    public let version: String
    public let path: URL

    public init(kind: RuntimeKind, version: String, path: URL) {
        self.kind = kind
        self.version = version
        self.path = path
    }

    /// Wine: the loader binary. Wine 9+ wow64 builds ship a single `wine`; older ones `wine64`.
    public var wineBinary: URL {
        let wine = path.appendingPathComponent("bin/wine")
        if FileManager.default.isExecutableFile(atPath: wine.path) { return wine }
        return path.appendingPathComponent("bin/wine64")
    }

    /// DXMT / GPTK: directory containing `x86_64-windows/` and `x86_64-unix/`, for WINEDLLPATH.
    public var wineDLLDirectory: URL {
        switch kind {
        case .wine, .dxmt: return path
        case .gptk: return path.appendingPathComponent("wine")
        }
    }

    /// GPTK: directory holding D3DMetal.framework and libd3dshared.dylib.
    public var externalLibraryDirectory: URL {
        path.appendingPathComponent("external")
    }

    /// Finds the runtime root inside a user-supplied directory, or explains why it isn't one.
    public static func resolveRoot(kind: RuntimeKind, at path: URL) throws -> URL {
        let fm = FileManager.default
        let candidates: [URL]
        let marker: String
        switch kind {
        case .wine:
            candidates = [path, path.appendingPathComponent("Contents/Resources/wine")]
            marker = "bin/wine"
        case .dxmt:
            candidates = [path, path.appendingPathComponent("lib/wine")]
            marker = "x86_64-windows/d3d11.dll"
        case .gptk:
            candidates = [path.appendingPathComponent("redist/lib"), path.appendingPathComponent("lib"), path]
            marker = "external/D3DMetal.framework"
        }
        for candidate in candidates {
            if fm.fileExists(atPath: candidate.appendingPathComponent(marker).path) { return candidate }
            if kind == .wine, fm.fileExists(atPath: candidate.appendingPathComponent("bin/wine64").path) {
                return candidate
            }
        }
        throw NeutronError.invalidRuntime(kind, path: path.path, reason: "could not find \(marker)")
    }
}

/// Registry of runtimes, stored as a JSON manifest. Runtimes stay where the user put them;
/// later phases will download managed copies into `NeutronPaths.runtimes`.
public struct RuntimeStore: Sendable {
    public let paths: NeutronPaths

    public init(paths: NeutronPaths) {
        self.paths = paths
    }

    public func list() throws -> [Runtime] {
        let manifest = paths.runtimeManifest
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        return try JSONDecoder().decode([Runtime].self, from: Data(contentsOf: manifest))
    }

    @discardableResult
    public func add(kind: RuntimeKind, path: URL, version: String? = nil) throws -> Runtime {
        let root = try Runtime.resolveRoot(kind: kind, at: path.standardizedFileURL)
        let runtime = Runtime(kind: kind, version: version ?? path.lastPathComponent, path: root)
        var all = try list()
        if all.contains(where: { $0.kind == kind && $0.version == runtime.version }) {
            throw NeutronError.runtimeExists(kind, version: runtime.version)
        }
        all.append(runtime)
        try save(all)
        return runtime
    }

    public func remove(kind: RuntimeKind, version: String) throws {
        var all = try list()
        guard let index = all.firstIndex(where: { $0.kind == kind && $0.version == version }) else {
            throw NeutronError.runtimeNotFound(kind, version: version)
        }
        all.remove(at: index)
        try save(all)
    }

    /// The requested version, or the newest registered one when `version` is nil.
    public func find(_ kind: RuntimeKind, version: String? = nil) throws -> Runtime {
        let matching = try list().filter { $0.kind == kind }
        let found: Runtime?
        if let version {
            found = matching.first { $0.version == version }
        } else {
            found = matching.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
        }
        guard let found else { throw NeutronError.runtimeNotFound(kind, version: version) }
        return found
    }

    private func save(_ runtimes: [Runtime]) throws {
        try FileManager.default.createDirectory(at: paths.runtimes, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(runtimes).write(to: paths.runtimeManifest, options: .atomic)
    }
}
