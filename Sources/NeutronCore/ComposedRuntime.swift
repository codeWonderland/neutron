import Foundation

/// A Wine build with a backend's DLLs overlaid, cached under `NeutronPaths.composed`.
///
/// Phase 0 showed WINEDLLPATH can't apply DXMT: Wine searches its own `lib/wine` before
/// WINEDLLPATH, and it only loads a builtin that also has a copy in the prefix's system
/// directory. So a backend is overlaid onto a clone of the Wine build instead. On APFS the
/// clone shares blocks with the original, so it is nearly free, and the registered runtimes
/// are never modified.
public struct ComposedRuntime: Equatable, Sendable {
    public let wine: Runtime
    public let backend: Runtime
    public let path: URL

    public init(wine: Runtime, backend: Runtime, paths: NeutronPaths) {
        self.wine = wine
        self.backend = backend
        let name = "\(wine.version)+\(backend.kind.rawValue)-\(backend.version)"
            .replacingOccurrences(of: "/", with: "_")
        self.path = paths.composed.appendingPathComponent(name, isDirectory: true)
    }

    /// Same binary as the source build; computed from it so it's right before `build()` runs.
    public var wineBinary: URL {
        path.appendingPathComponent("bin").appendingPathComponent(wine.wineBinary.lastPathComponent)
    }

    /// Backend files and where they go in the composed build, relative to its root.
    var overlay: [(source: URL, destination: String)] {
        var pairs: [(URL, String)] = []
        for arch in ["x86_64-windows", "i386-windows", "x86_64-unix"] {
            pairs.append((backend.wineDLLDirectory.appendingPathComponent(arch), "lib/wine/\(arch)"))
        }
        if backend.kind == .gptk {
            // Mirrors GPTK's redist/lib layout, so the unix libraries' relative paths to
            // D3DMetal.framework still resolve. Unverified until Phase 0 tests GPTK.
            pairs.append((backend.externalLibraryDirectory, "lib/external"))
        }
        return pairs.filter { FileManager.default.fileExists(atPath: $0.0.path) }
    }

    /// Records which runtimes a composed build came from, so a re-registered runtime rebuilds it.
    private var stampURL: URL { path.appendingPathComponent(".neutron-composed.json") }
    private var stamp: Data { Data("[\"\(wine.path.path)\", \"\(backend.path.path)\"]".utf8) }

    public var isBuilt: Bool {
        (try? Data(contentsOf: stampURL)) == stamp
    }

    /// Clones Wine and overlays the backend, unless an up-to-date build already exists.
    public func build() throws {
        guard !isBuilt else { return }
        let fm = FileManager.default
        let staging = path.deletingLastPathComponent()
            .appendingPathComponent(".\(path.lastPathComponent).partial", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: wine.path, to: staging)

        for (source, destination) in overlay {
            let target = staging.appendingPathComponent(destination, isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: source.path) where !name.hasPrefix(".") {
                let to = target.appendingPathComponent(name)
                try? fm.removeItem(at: to)
                try fm.copyItem(at: source.appendingPathComponent(name), to: to)
            }
        }
        try stamp.write(to: staging.appendingPathComponent(".neutron-composed.json"))
        try? fm.removeItem(at: path)
        try fm.moveItem(at: staging, to: path)
    }

    /// The backend's Windows DLLs that the prefix has no copy of. Wine only loads a builtin
    /// DLL when the prefix has one, so these must be installed (`wineboot -u`) before launch.
    public func missingPrefixDLLs(winePrefix: URL) -> [String] {
        let fm = FileManager.default
        let systemDirectories = ["x86_64-windows": "system32", "i386-windows": "syswow64"]
        var missing: [String] = []
        for (arch, system) in systemDirectories.sorted(by: { $0.key < $1.key }) {
            let source = backend.wineDLLDirectory.appendingPathComponent(arch)
            let names = (try? fm.contentsOfDirectory(atPath: source.path)) ?? []
            for name in names.sorted() where name.lowercased().hasSuffix(".dll") {
                let relative = "drive_c/windows/\(system)/\(name)"
                if !fm.fileExists(atPath: winePrefix.appendingPathComponent(relative).path) {
                    missing.append(relative)
                }
            }
        }
        return missing
    }
}
