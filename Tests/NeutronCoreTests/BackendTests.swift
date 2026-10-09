import XCTest
@testable import NeutronCore

final class BackendTests: XCTestCase {
    func testResolverPrefersD3D12() {
        let pick = BackendResolver.recommend(imports: ["d3d11.dll", "d3d12.dll", "dxgi.dll"])
        XCTAssertEqual(pick.backend, .d3dmetal)
        XCTAssertEqual(pick.fallback, .dxmt)
        // D3D12 only: nothing else can run it.
        let only = BackendResolver.recommend(imports: ["d3d12.dll", "dxgi.dll"])
        XCTAssertEqual(only.backend, .d3dmetal)
        XCTAssertNil(only.fallback)
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
        XCTAssertEqual(setup.overlay, runtime)
        XCTAssertTrue(setup.environment.isEmpty)
    }

    func testD3DMetalSetup() throws {
        let runtime = Runtime(kind: .gptk, version: "2.1", path: URL(fileURLWithPath: "/rt/gptk/redist/lib"))
        let setup = try BackendSetup.make(for: .d3dmetal, runtime: runtime)
        XCTAssertEqual(setup.overridesString, "d3d11=b;d3d12=b;dxgi=b")
        XCTAssertEqual(setup.overlay, runtime)
    }

    func testWineD3DHasNoOverlay() throws {
        XCTAssertNil(try BackendSetup.make(for: .wined3d, runtime: nil).overlay)
    }

    func testBackendRequiresMatchingRuntime() {
        XCTAssertThrowsError(try BackendSetup.make(for: .dxmt, runtime: nil))
        let gptk = Runtime(kind: .gptk, version: "2.1", path: URL(fileURLWithPath: "/rt/gptk"))
        XCTAssertThrowsError(try BackendSetup.make(for: .dxmt, runtime: gptk))
    }
}
