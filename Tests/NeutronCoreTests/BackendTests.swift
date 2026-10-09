import XCTest
@testable import NeutronCore

final class BackendTests: XCTestCase {
    func testResolverPrefersD3D12() {
        let pick = BackendResolver.recommend(imports: ["d3d11.dll", "d3d12.dll", "dxgi.dll"])
        XCTAssertEqual(pick.backend, .d3dmetal)
    }

    func testResolverMapsD3D11ToDXMT() {
        XCTAssertEqual(BackendResolver.recommend(imports: ["kernel32.dll", "dxgi.dll"]).backend, .dxmt)
    }

    func testResolverFallsBackToWineD3D() {
        XCTAssertEqual(BackendResolver.recommend(imports: ["d3d9.dll"]).backend, .wined3d)
        XCTAssertEqual(BackendResolver.recommend(imports: []).backend, .wined3d)
    }

    func testDXMTSetup() throws {
        let runtime = Runtime(kind: .dxmt, version: "0.60", path: URL(fileURLWithPath: "/rt/dxmt"))
        let setup = try BackendSetup.make(for: .dxmt, runtime: runtime)
        XCTAssertEqual(setup.overridesString, "d3d10core=b;d3d11=b;dxgi=b;winemetal=b")
        XCTAssertEqual(setup.dllPaths.map(\.path), ["/rt/dxmt"])
    }

    func testD3DMetalSetup() throws {
        let runtime = Runtime(kind: .gptk, version: "2.1", path: URL(fileURLWithPath: "/rt/gptk/redist/lib"))
        let setup = try BackendSetup.make(for: .d3dmetal, runtime: runtime)
        XCTAssertEqual(setup.dllPaths.map(\.path), ["/rt/gptk/redist/lib/wine"])
        XCTAssertEqual(setup.environment["DYLD_FALLBACK_FRAMEWORK_PATH"], "/rt/gptk/redist/lib/external")
    }

    func testBackendRequiresMatchingRuntime() {
        XCTAssertThrowsError(try BackendSetup.make(for: .dxmt, runtime: nil))
    }
}
