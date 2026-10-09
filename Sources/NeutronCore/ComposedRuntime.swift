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
    ///
    /// DXMT: everything in its `x86_64-windows`, `i386-windows` and `x86_64-unix` folders.
    /// GPTK: only D3DMetal's own files: the `x86_64-unix` libraries that are symlinks into
    /// `external/` (to `libd3dshared.dylib`), the 64-bit DLLs that have one, and `external/`.
    /// A full Wine build registered as GPTK (e.g. Gcenx's game-porting-toolkit) also has
    /// hundreds of its own Wine DLLs in those folders, which must not replace ours.
    var overlay: [(source: URL, destination: String)] {
        let fm = FileManager.default
        func entries(_ directory: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }
        let dlls = backend.wineDLLDirectory
        var files: [(URL, String)] = []
        switch backend.kind {
        case .gptk:
            let unixDirectory = dlls.appendingPathComponent("x86_64-unix")
            let external = backend.externalLibraryDirectory.resolvingSymlinksInPath().path + "/"
            let allUnix = entries(unixDirectory).filter { $0.hasSuffix(".so") }
            // D3DMetal's unix libraries are symlinks into external/. A folder with no such
            // links and few DLLs (Apple's redist) holds only D3DMetal, so take all of it.
            var unix = allUnix.filter {
                unixDirectory.appendingPathComponent($0).resolvingSymlinksInPath().path.hasPrefix(external)
            }
            if unix.isEmpty, entries(dlls.appendingPathComponent("x86_64-windows")).count < 40 { unix = allUnix }
            let stems = Set(unix.map { String($0.dropLast(3)).lowercased() })
            for name in unix {
                files.append((dlls.appendingPathComponent("x86_64-unix/\(name)"), "lib/wine/x86_64-unix/\(name)"))
            }
            for name in entries(dlls.appendingPathComponent("x86_64-windows"))
            where name.lowercased().hasSuffix(".dll") && stems.contains(String(name.dropLast(4)).lowercased()) {
                files.append((dlls.appendingPathComponent("x86_64-windows/\(name)"), "lib/wine/x86_64-windows/\(name)"))
            }
            // Same relative position as GPTK's redist/lib/external, so the symlinks resolve.
            for name in entries(backend.externalLibraryDirectory) {
                files.append((backend.externalLibraryDirectory.appendingPathComponent(name), "lib/external/\(name)"))
            }
        case .dxmt, .wine:
            for arch in ["x86_64-windows", "i386-windows", "x86_64-unix"] {
                for name in entries(dlls.appendingPathComponent(arch)) {
                    files.append((dlls.appendingPathComponent("\(arch)/\(name)"), "lib/wine/\(arch)/\(name)"))
                }
            }
        }
        return files
    }

    /// Records what a composed build came from: the overlay rules' version, both runtime paths,
    /// and the size and date of every overlaid file and of Wine's ntdll.so, so re-registering
    /// or updating a runtime in place rebuilds it.
    private var stampURL: URL { path.appendingPathComponent(".neutron-composed.json") }
    private var stamp: Data {
        let layout = 4  // bump when the overlay rules change
        let sources = overlay.map(\.source) + [wine.path.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")]
        let files = sources.map { url -> String in
            // attributesOfItem doesn't follow symlinks, so GPTK's links count as themselves.
            let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(url.path):\(size):\(Int64(date))"
        }
        let object: [Any] = [layout, wine.path.path, backend.path.path, files]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

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
            let target = staging.appendingPathComponent(destination)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: source, to: target)  // symlinks are copied as links
        }
        try stamp.write(to: staging.appendingPathComponent(".neutron-composed.json"))
        try? fm.removeItem(at: path)
        try fm.moveItem(at: staging, to: path)
    }

    /// The backend's Windows DLLs that the prefix has no copy of. Wine only loads a builtin
    /// DLL when the prefix has one, so these must be installed (`wineboot -u`) before launch.
    public func missingPrefixDLLs(winePrefix: URL) -> [String] {
        let systemDirectories = ["lib/wine/x86_64-windows/": "system32", "lib/wine/i386-windows/": "syswow64"]
        var missing: [String] = []
        for (_, destination) in overlay where destination.lowercased().hasSuffix(".dll") {
            guard let (prefix, system) = systemDirectories.first(where: { destination.hasPrefix($0.key) }) else { continue }
            let relative = "drive_c/windows/\(system)/\(destination.dropFirst(prefix.count))"
            if !FileManager.default.fileExists(atPath: winePrefix.appendingPathComponent(relative).path) {
                missing.append(relative)
            }
        }
        return missing.sorted()
    }
}
