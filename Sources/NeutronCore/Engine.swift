import Foundation

/// An engine that ships several renderers and picks one at runtime, so import tables alone
/// can't say which API a game will use (Unity and Unreal import both d3d11 and d3d12, or
/// neither; Godot imports none).
public enum GameEngine: Equatable, Sendable {
    case unity(version: String?)
    case unreal(version: String?)
    case godot(version: String?)

    public var description: String {
        switch self {
        case .unity(let version): return "Unity" + (version.map { " \($0)" } ?? "")
        case .unreal(let version): return "Unreal" + (version.map { " \($0)" } ?? "")
        case .godot(let version): return "Godot" + (version.map { " \($0)" } ?? "")
        }
    }

    private var majorVersion: Int? {
        switch self {
        case .unity(let version?), .unreal(let version?), .godot(let version?):
            return Int(version.prefix { $0.isNumber })
        default:
            return nil
        }
    }

    /// Unity 5+ and Unreal 4+ can render with D3D11; Unity 4 and older are D3D9-era.
    /// Godot never uses Direct3D under Neutron (see `arguments(for:userArguments:)`).
    public var supportsD3D11: Bool {
        switch self {
        case .unity: return (majorVersion ?? 5) >= 5
        case .unreal: return true
        case .godot: return false
        }
    }

    /// Flags that pick a graphics API. If the user passes one, Neutron adds none.
    var apiArguments: Set<String> {
        switch self {
        case .unity: return ["-force-d3d11", "-force-d3d12", "-force-vulkan", "-force-glcore", "-force-d3d11-no-singlethreaded"]
        case .unreal: return ["-dx11", "-d3d11", "-dx12", "-d3d12", "-vulkan", "-sm5", "-sm6"]
        case .godot: return ["--rendering-driver", "--rendering-method", "--video-driver"]
        }
    }

    /// Extra launch arguments for `backend`.
    ///
    /// Unity and Unreal on backends without D3D12 get their force-D3D11 flag. Godot 4 gets
    /// `--rendering-driver vulkan` (except on D3DMetal): under Wine its default driver fails
    /// and it falls back to the OpenGL Compatibility renderer, while Vulkan runs Forward+
    /// through Wine's MoltenVK (Phase 0, Fortune Mill). Godot 3 only has OpenGL.
    public func arguments(for backend: GraphicsBackend, userArguments: [String]) -> [String] {
        guard backend != .d3dmetal else { return [] }
        if userArguments.contains(where: { apiArguments.contains($0.lowercased()) }) { return [] }
        switch self {
        case .unity: return ["-force-d3d11"]
        case .unreal: return ["-dx11"]
        case .godot: return (majorVersion ?? 4) >= 4 ? ["--rendering-driver", "vulkan"] : []
        }
    }
}

/// What Neutron found out about a game's engine from the files around its executable.
public struct EngineDetection: Equatable, Sendable {
    public let engine: GameEngine
    /// The binary that holds the renderer. For an Unreal stub launcher this is the
    /// `*-Shipping.exe` it starts; otherwise the executable itself.
    public let renderer: URL
    /// The game ships Microsoft's D3D12 Agility SDK (`D3D12/D3D12Core.dll`) next to its
    /// renderer, which in Phase 0 marked every Unity 6 and Unreal 5 game with a D3D12 path.
    public let shipsD3D12AgilitySDK: Bool

    public static func detect(executable: URL) -> EngineDetection? {
        let fm = FileManager.default
        let directory = executable.deletingLastPathComponent()
        let stem = executable.deletingPathExtension().lastPathComponent

        // Unity: UnityPlayer.dll (2017+) or <Name>_Data beside the exe.
        let dataDirectory = directory.appendingPathComponent("\(stem)_Data", isDirectory: true)
        if fm.fileExists(atPath: directory.appendingPathComponent("UnityPlayer.dll").path)
            || fm.fileExists(atPath: dataDirectory.path) {
            return EngineDetection(engine: .unity(version: unityVersion(dataDirectory: dataDirectory)),
                                   renderer: executable, shipsD3D12AgilitySDK: hasAgilitySDK(in: directory))
        }

        // Godot: the engine banner (and its version) are in the executable.
        if let version = godotVersion(executable: executable) {
            return EngineDetection(engine: .godot(version: version.isEmpty ? nil : version),
                                   renderer: executable, shipsD3D12AgilitySDK: false)
        }

        // Unreal: a Shipping build itself, a stub launcher (next to Engine/, or with a
        // `<Project>/Binaries/Win64/<stub>-…-Shipping.exe`), or a game binary under
        // Binaries/Win64 inside an Unreal tree.
        let renderer: URL?
        if executable.lastPathComponent.lowercased().hasSuffix("-shipping.exe") {
            renderer = executable
        } else if let shipping = shippingExecutable(near: directory, stem: stem,
                                                    allowUnnamed: isDirectory(directory.appendingPathComponent("Engine"))) {
            renderer = shipping
        } else if directory.path.lowercased().hasSuffix("/binaries/win64"),
                  isDirectory(directory.deletingLastPathComponent().deletingLastPathComponent()
                      .deletingLastPathComponent().appendingPathComponent("Engine")) {
            renderer = executable
        } else {
            renderer = nil
        }
        guard let renderer else { return nil }
        return EngineDetection(engine: .unreal(version: unrealVersion(executable: renderer)), renderer: renderer,
                               shipsD3D12AgilitySDK: hasAgilitySDK(in: renderer.deletingLastPathComponent()))
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func hasAgilitySDK(in directory: URL) -> Bool {
        ["D3D12/D3D12Core.dll", "D3D12/x64/D3D12Core.dll"].contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Finds `<root>/<Project>/Binaries/Win64/*-Shipping.exe` (or under `Engine/`) named after
    /// the stub (`FSD.exe` → `FSD-Win64-Shipping.exe`), or the only one when `allowUnnamed`.
    private static func shippingExecutable(near root: URL, stem: String, allowUnnamed: Bool) -> URL? {
        let fm = FileManager.default
        let projects = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        var found: [URL] = []
        for project in projects {
            let binaries = root.appendingPathComponent(project).appendingPathComponent("Binaries/Win64")
            for name in ((try? fm.contentsOfDirectory(atPath: binaries.path)) ?? []).sorted()
            where name.lowercased().hasSuffix("-shipping.exe") {
                found.append(binaries.appendingPathComponent(name))
            }
        }
        let prefix = stem.lowercased() + "-"
        if let named = found.first(where: { $0.lastPathComponent.lowercased().hasPrefix(prefix) }) { return named }
        return allowUnnamed && found.count == 1 ? found[0] : nil
    }

    /// The version string Unity writes near the start of its serialized data, e.g. "6000.3.0f1".
    static func unityVersion(dataDirectory: URL) -> String? {
        for name in ["globalgamemanagers", "data.unity3d", "mainData"] {
            guard let handle = try? FileHandle(forReadingFrom: dataDirectory.appendingPathComponent(name)) else { continue }
            defer { try? handle.close() }
            let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
            if let match = head.range(of: #"(20\d\d|6\d\d\d|[2-5])\.\d+\.\d+[abfpx]\d+"#, options: .regularExpression) {
                return String(head[match])
            }
        }
        return nil
    }

    /// Godot executables contain the engine's URL and a version like "4.5.1.stable.mono".
    /// Returns nil for non-Godot executables and "" when the version can't be read.
    static func godotVersion(executable: URL) -> String? {
        guard let data = try? Data(contentsOf: executable, options: .alwaysMapped) else { return nil }
        let url = Array("https://godotengine.org".utf8)
        let found = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return memmem(base, buffer.count, url, url.count) != nil
        }
        guard found else { return nil }
        for major in ["4.", "3."] {
            let marker = Array(".stable".utf8)
            let version: String? = data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return nil }
                var offset = 0
                while offset < buffer.count, let hit = memmem(base + offset, buffer.count - offset, marker, marker.count) {
                    let end = base.distance(to: hit)
                    var start = end
                    while start > 0, start > end - 12, buffer[start - 1] == UInt8(ascii: ".") || (48...57).contains(buffer[start - 1]) {
                        start -= 1
                    }
                    let text = String(decoding: buffer[start..<end], as: UTF8.self)
                    if text.hasPrefix(major), text.split(separator: ".").count >= 2 { return text }
                    offset = end + marker.count
                }
                return nil
            }
            if let version { return version }
        }
        return ""
    }

    /// The engine branch Unreal embeds as UTF-16, e.g. "++UE5+Release-5.3" → "5.3". Custom
    /// engine branches often leave it out.
    static func unrealVersion(executable: URL) -> String? {
        guard let data = try? Data(contentsOf: executable, options: .alwaysMapped) else { return nil }
        let marker = Array("++UE".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> String? in
            guard let base = buffer.baseAddress else { return nil }
            var offset = 0
            while offset < buffer.count,
                  let hit = memmem(base + offset, buffer.count - offset, marker, marker.count) {
                let start = base.distance(to: hit)
                // Read up to 40 UTF-16 code units: "++UE5+Release-5.3".
                var text = ""
                var i = start
                while i + 1 < buffer.count, text.count < 40 {
                    let unit = UInt16(buffer[i]) | UInt16(buffer[i + 1]) << 8
                    guard unit >= 0x20, unit < 0x7F else { break }
                    text.append(Character(Unicode.Scalar(UInt8(unit))))
                    i += 2
                }
                if let range = text.range(of: #"(?<=\+Release-)\d+\.\d+"#, options: .regularExpression) {
                    return String(text[range])
                }
                offset = start + marker.count
            }
            return nil
        }
    }
}
