import XCTest
@testable import NeutronCore

final class ComposedRuntimeTests: XCTestCase {
    private var paths: NeutronPaths!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neutron-tests-\(UUID().uuidString)")
        paths = NeutronPaths(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: paths.root)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Fake Wine and DXMT trees laid out like Gcenx Wine 11.18 and DXMT v0.80.
    private func makeRuntimes() throws -> (wine: Runtime, dxmt: Runtime) {
        let wineRoot = paths.root.appendingPathComponent("builds/wine")
        try write("wine", to: wineRoot.appendingPathComponent("bin/wine"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineRoot.appendingPathComponent("bin/wine").path)
        try write("wine d3d11", to: wineRoot.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll"))
        try write("wine kernel32", to: wineRoot.appendingPathComponent("lib/wine/x86_64-windows/kernel32.dll"))

        let dxmtRoot = paths.root.appendingPathComponent("builds/dxmt")
        for arch in ["x86_64-windows", "i386-windows"] {
            try write("dxmt d3d11", to: dxmtRoot.appendingPathComponent("\(arch)/d3d11.dll"))
            try write("dxmt winemetal", to: dxmtRoot.appendingPathComponent("\(arch)/winemetal.dll"))
        }
        try write("dxmt unix", to: dxmtRoot.appendingPathComponent("x86_64-unix/winemetal.so"))
        return (Runtime(kind: .wine, version: "11.18", path: wineRoot),
                Runtime(kind: .dxmt, version: "v0.80", path: dxmtRoot))
    }

    func testBuildOverlaysBackendWithoutTouchingWine() throws {
        let (wine, dxmt) = try makeRuntimes()
        let composed = ComposedRuntime(wine: wine, backend: dxmt, paths: paths)
        XCTAssertFalse(composed.isBuilt)
        try composed.build()
        XCTAssertTrue(composed.isBuilt)

        let lib = composed.path.appendingPathComponent("lib/wine")
        XCTAssertEqual(try read(lib.appendingPathComponent("x86_64-windows/d3d11.dll")), "dxmt d3d11")
        XCTAssertEqual(try read(lib.appendingPathComponent("x86_64-windows/kernel32.dll")), "wine kernel32")
        XCTAssertEqual(try read(lib.appendingPathComponent("i386-windows/winemetal.dll")), "dxmt winemetal")
        XCTAssertEqual(try read(lib.appendingPathComponent("x86_64-unix/winemetal.so")), "dxmt unix")
        XCTAssertEqual(composed.wineBinary, composed.path.appendingPathComponent("bin/wine"))

        // The registered Wine build is untouched.
        XCTAssertEqual(try read(wine.path.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")), "wine d3d11")
    }

    func testRebuildsWhenSourceRuntimeMoves() throws {
        let (wine, dxmt) = try makeRuntimes()
        try ComposedRuntime(wine: wine, backend: dxmt, paths: paths).build()

        let moved = paths.root.appendingPathComponent("builds/wine-moved")
        try FileManager.default.copyItem(at: wine.path, to: moved)
        try write("wine 2", to: moved.appendingPathComponent("lib/wine/x86_64-windows/kernel32.dll"))
        let rebuilt = ComposedRuntime(wine: Runtime(kind: .wine, version: "11.18", path: moved), backend: dxmt, paths: paths)
        XCTAssertFalse(rebuilt.isBuilt)
        try rebuilt.build()
        XCTAssertEqual(try read(rebuilt.path.appendingPathComponent("lib/wine/x86_64-windows/kernel32.dll")), "wine 2")
    }

    func testMissingPrefixDLLs() throws {
        let (wine, dxmt) = try makeRuntimes()
        let composed = ComposedRuntime(wine: wine, backend: dxmt, paths: paths)
        let prefix = paths.root.appendingPathComponent("pfx")
        try write("", to: prefix.appendingPathComponent("drive_c/windows/system32/d3d11.dll"))
        try write("", to: prefix.appendingPathComponent("drive_c/windows/syswow64/d3d11.dll"))

        XCTAssertEqual(composed.missingPrefixDLLs(winePrefix: prefix), [
            "drive_c/windows/syswow64/winemetal.dll",
            "drive_c/windows/system32/winemetal.dll",
        ])
    }
}
