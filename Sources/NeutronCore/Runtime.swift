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
    /// Wine: folders of dylibs the build expects its host app to provide (e.g. Sikarugir
    /// engines need the wrapper's `Contents/Frameworks`); passed as DYLD_FALLBACK_LIBRARY_PATH.
    public var libraryPaths: [URL]?

    public init(kind: RuntimeKind, version: String, path: URL, libraryPaths: [URL]? = nil) {
        self.kind = kind
        self.version = version
        self.path = path
        self.libraryPaths = libraryPaths
    }

    /// Wine: the loader binary. Wine 9+ wow64 builds ship a single `wine`; older ones `wine64`.
    public var wineBinary: URL {
        let wine = path.appendingPathComponent("bin/wine")
        if FileManager.default.isExecutableFile(atPath: wine.path) { return wine }
        return path.appendingPathComponent("bin/wine64")
    }

    /// DXMT / GPTK: directory containing `x86_64-windows/` and `x86_64-unix/`, overlaid onto
    /// Wine's `lib/wine` by `ComposedRuntime`.
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
    /// Also looks one level down, since release archives often extract into a wrapper folder
    /// (Gcenx Wine: `wine-devel-11.18/Wine Devel.app`; DXMT: `dxmt-v0.80/v0.80`).
    public static func resolveRoot(kind: RuntimeKind, at path: URL) throws -> URL {
        let fm = FileManager.default
        let markers: [String]
        switch kind {
        case .wine: markers = ["bin/wine", "bin/wine64"]
        case .dxmt: markers = ["x86_64-windows/d3d11.dll"]
        case .gptk: markers = ["external/D3DMetal.framework"]
        }
        func candidates(in directory: URL) -> [URL] {
            switch kind {
            case .wine: return [directory, directory.appendingPathComponent("Contents/Resources/wine")]
            case .dxmt: return [directory, directory.appendingPathComponent("lib/wine")]
            case .gptk: return [directory.appendingPathComponent("redist/lib"), directory.appendingPathComponent("lib"), directory]
            }
        }
        let children = ((try? fm.contentsOfDirectory(atPath: path.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { path.appendingPathComponent($0, isDirectory: true) }
        for directory in [path] + children {
            for candidate in candidates(in: directory)
            where markers.contains(where: { fm.fileExists(atPath: candidate.appendingPathComponent($0).path) }) {
                return candidate
            }
        }
        throw NeutronError.invalidRuntime(kind, path: path.path, reason: "could not find \(markers[0])")
    }

    /// Version label when the user gives none: the folder name, or for an app bundle its
    /// name and version ("Wine Devel.app" → "wine-devel-11.18").
    public static func defaultVersion(for path: URL) -> String {
        guard path.pathExtension == "app" else { return path.lastPathComponent }
        let name = path.deletingPathExtension().lastPathComponent.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let plist = path.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let version = info["CFBundleShortVersionString"] as? String
        else { return name }
        return "\(name)-\(version)"
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
    public func add(kind: RuntimeKind, path: URL, version: String? = nil, libraryPaths: [URL] = []) throws -> Runtime {
        let root = try Runtime.resolveRoot(kind: kind, at: path.standardizedFileURL)
        for library in libraryPaths where !FileManager.default.fileExists(atPath: library.path) {
            throw NeutronError.fileNotFound(library.path)
        }
        let runtime = Runtime(kind: kind, version: version ?? Runtime.defaultVersion(for: path.standardizedFileURL), path: root,
                              libraryPaths: libraryPaths.isEmpty ? nil : libraryPaths.map(\.standardizedFileURL))
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
