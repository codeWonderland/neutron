import Foundation

public enum GraphicsBackend: String, Codable, CaseIterable, Sendable {
    /// Wine's built-in D3D → OpenGL. Slow, but needs nothing extra; the fallback for D3D9 and older.
    case wined3d
    /// DXMT: D3D10/11 → Metal.
    case dxmt
    /// Apple's D3DMetal from the Game Porting Toolkit: D3D11/12 → Metal.
    case d3dmetal

    /// The runtime this backend needs on top of Wine.
    public var requiredRuntime: RuntimeKind? {
        switch self {
        case .wined3d: return nil
        case .dxmt: return .dxmt
        case .d3dmetal: return .gptk
        }
    }
}

/// What a backend adds to Wine's launch environment.
///
/// Neither DXMT nor D3DMetal is copied into the prefix or the Wine build. Both are put on
/// WINEDLLPATH and forced to "builtin", so prefixes and runtimes stay clean and swappable.
/// Phase 0 has to confirm Wine loads the unix-side libraries this way (docs/phase0-spike.md).
public struct BackendSetup: Equatable, Sendable {
    public var dllOverrides: [String: String] = [:]
    public var dllPaths: [URL] = []
    public var environment: [String: String] = [:]

    public init() {}

    /// `WINEDLLOVERRIDES` syntax, sorted so output is stable.
    public var overridesString: String {
        dllOverrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    }

    public static func make(for backend: GraphicsBackend, runtime: Runtime?) throws -> BackendSetup {
        var setup = BackendSetup()
        let d3d11 = ["d3d11", "dxgi", "d3d10core"]
        switch backend {
        case .wined3d:
            // Force builtin so DLLs a game or installer dropped into the prefix don't take over.
            for dll in d3d11 { setup.dllOverrides[dll] = "b" }
        case .dxmt:
            guard let runtime, runtime.kind == .dxmt else { throw NeutronError.runtimeNotFound(.dxmt, version: nil) }
            for dll in d3d11 + ["winemetal"] { setup.dllOverrides[dll] = "b" }
            setup.dllPaths = [runtime.wineDLLDirectory]
        case .d3dmetal:
            guard let runtime, runtime.kind == .gptk else { throw NeutronError.runtimeNotFound(.gptk, version: nil) }
            for dll in ["d3d11", "d3d12", "dxgi"] { setup.dllOverrides[dll] = "b" }
            setup.dllPaths = [runtime.wineDLLDirectory]
            let external = runtime.externalLibraryDirectory.path
            setup.environment["DYLD_FALLBACK_LIBRARY_PATH"] = external
            setup.environment["DYLD_FALLBACK_FRAMEWORK_PATH"] = external
        }
        return setup
    }
}

public struct BackendRecommendation: Equatable, Sendable {
    public let backend: GraphicsBackend
    public let reason: String
}

public enum BackendResolver {
    /// Picks a backend from the DLLs a game imports (lowercased names, e.g. "d3d11.dll").
    public static func recommend(imports: Set<String>) -> BackendRecommendation {
        if imports.contains("d3d12.dll") {
            return BackendRecommendation(backend: .d3dmetal, reason: "imports d3d12.dll; D3D12 needs D3DMetal")
        }
        if let dll = ["d3d11.dll", "dxgi.dll", "d3d10.dll", "d3d10_1.dll", "d3d10core.dll"].first(where: { imports.contains($0) }) {
            return BackendRecommendation(backend: .dxmt, reason: "imports \(dll); D3D10/11 runs on DXMT")
        }
        if let dll = ["d3d9.dll", "d3d8.dll", "ddraw.dll", "opengl32.dll"].first(where: { imports.contains($0) }) {
            return BackendRecommendation(backend: .wined3d, reason: "imports \(dll); handled by wined3d")
        }
        return BackendRecommendation(
            backend: .wined3d,
            reason: "no graphics API imports found; the game may load its renderer at runtime"
        )
    }
}
