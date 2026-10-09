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

/// What a backend adds to a Wine launch.
///
/// DXMT and D3DMetal are overlaid onto a clone of the Wine build (`ComposedRuntime`) and
/// forced to "builtin". Registered runtimes are never modified. Phase 0 ruled out
/// WINEDLLPATH; see the decision log in PROJECT-OUTLINE.md.
public struct BackendSetup: Equatable, Sendable {
    public var dllOverrides: [String: String] = [:]
    /// Backend runtime to overlay onto Wine; nil runs Wine as registered.
    public var overlay: Runtime?
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
            setup.overlay = runtime
        case .d3dmetal:
            guard let runtime, runtime.kind == .gptk else { throw NeutronError.runtimeNotFound(.gptk, version: nil) }
            for dll in ["d3d11", "d3d12", "dxgi"] { setup.dllOverrides[dll] = "b" }
            setup.overlay = runtime
        }
        return setup
    }
}

public struct BackendRecommendation: Equatable, Sendable {
    public let backend: GraphicsBackend
    public let reason: String
    /// Used instead when `backend`'s runtime isn't registered (e.g. no GPTK): an engine game
    /// that can be switched to D3D11 still runs on DXMT.
    public var fallback: GraphicsBackend?

    public init(backend: GraphicsBackend, reason: String, fallback: GraphicsBackend? = nil) {
        self.backend = backend
        self.reason = reason
        self.fallback = fallback
    }
}

public enum BackendResolver {
    /// Picks a backend from the DLLs a game imports (lowercased names, e.g. "d3d11.dll") and,
    /// for engines that choose their renderer at runtime, from what the engine ships.
    public static func recommend(imports: Set<String>, engine: EngineDetection? = nil) -> BackendRecommendation {
        let d3d11 = ["d3d11.dll", "dxgi.dll", "d3d10.dll", "d3d10_1.dll", "d3d10core.dll"]
        // Engines often load their renderer at runtime (many UnityPlayer.dll builds import
        // only opengl32.dll), so trust the engine over the import table.
        if let engine, engine.engine.supportsD3D11 {
            let name = engine.engine.description
            // Unity's D3D12 renderer needs D3D11On12, which D3DMetal lacks (Unity 6 falls back
            // to D3D11 there), so only Unreal benefits from D3DMetal.
            if engine.shipsD3D12AgilitySDK, case .unreal = engine.engine {
                return BackendRecommendation(
                    backend: .d3dmetal,
                    reason: "\(name) ships the D3D12 Agility SDK, so D3D12 is likely its main renderer",
                    fallback: .dxmt
                )
            }
            return BackendRecommendation(
                backend: .dxmt,
                reason: "\(name) can render with D3D11 (\(engine.engine.forceD3D11Argument)), which runs on DXMT"
            )
        }
        if imports.contains("d3d12.dll") {
            return BackendRecommendation(backend: .d3dmetal, reason: "imports d3d12.dll; D3D12 needs D3DMetal")
        }
        if let dll = d3d11.first(where: { imports.contains($0) }) {
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
