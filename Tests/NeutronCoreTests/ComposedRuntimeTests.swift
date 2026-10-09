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

    /// Updating a runtime in place (same folder, new files) rebuilds the composed build.
    func testRebuildsWhenBackendFilesChange() throws {
        let (wine, dxmt) = try makeRuntimes()
        let composed = ComposedRuntime(wine: wine, backend: dxmt, paths: paths)
        try composed.build()
        XCTAssertTrue(composed.isBuilt)

        try write("dxmt d3d11 v2 (bigger)", to: dxmt.path.appendingPathComponent("x86_64-windows/d3d11.dll"))
        XCTAssertFalse(composed.isBuilt)
        try composed.build()
        XCTAssertEqual(try read(composed.path.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")), "dxmt d3d11 v2 (bigger)")
        XCTAssertTrue(composed.isBuilt)
    }

    func testMissingPrefixDLLs() throws {
        let (wine, dxmt) = try makeRuntimes()
        let composed = ComposedRuntime(wine: wine, backend: dxmt, paths: paths)
        let prefix = paths.root.appendingPathComponent("pfx")
        try write("", to: prefix.appendingPathComponent("drive_c/windows/system32/d3d11.dll"))
        try write("", to: prefix.appendingPathComponent("drive_c/windows/syswow64/d3d11.dll"))

        XCTAssertEqual(composed.missingPrefixDLLs(winePrefix: prefix), [
            "drive_c/windows/system32/winemetal.dll",
            "drive_c/windows/syswow64/winemetal.dll",
        ])
    }

    /// A whole Wine build registered as GPTK (like Gcenx's game-porting-toolkit): only
    /// D3DMetal's files may be overlaid, not the build's own Wine DLLs.
    func testGPTKOverlayTakesOnlyD3DMetalFiles() throws {
        let (wine, _) = try makeRuntimes()
        let lib = paths.root.appendingPathComponent("builds/gptk/lib")
        try write("gptk d3d12", to: lib.appendingPathComponent("wine/x86_64-windows/d3d12.dll"))
        try write("gptk kernel32", to: lib.appendingPathComponent("wine/x86_64-windows/kernel32.dll"))
        try write("gptk d3d9 32-bit", to: lib.appendingPathComponent("wine/i386-windows/d3d9.dll"))
        try write("gptk ntdll", to: lib.appendingPathComponent("wine/x86_64-unix/ntdll.so"))
        try write("gptk wpcap", to: lib.appendingPathComponent("wine/x86_64-windows/wpcap.dll"))
        try write("gptk wpcap unix", to: lib.appendingPathComponent("wine/x86_64-unix/wpcap.so"))
        try write("shared", to: lib.appendingPathComponent("external/libd3dshared.dylib"))
        try write("framework", to: lib.appendingPathComponent("external/D3DMetal.framework/D3DMetal"))
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("wine/x86_64-unix"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: lib.appendingPathComponent("wine/x86_64-unix/d3d12.so").path,
                                                   withDestinationPath: "../../external/libd3dshared.dylib")
        let gptk = Runtime(kind: .gptk, version: "3.0", path: lib)
        let composed = ComposedRuntime(wine: wine, backend: gptk, paths: paths)
        try composed.build()

        let root = composed.path
        XCTAssertEqual(try read(root.appendingPathComponent("lib/wine/x86_64-windows/d3d12.dll")), "gptk d3d12")
        XCTAssertEqual(try read(root.appendingPathComponent("lib/wine/x86_64-windows/kernel32.dll")), "wine kernel32")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("lib/wine/i386-windows/d3d9.dll").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("lib/wine/x86_64-windows/wpcap.dll").path))
        let link = root.appendingPathComponent("lib/wine/x86_64-unix/d3d12.so")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "../../external/libd3dshared.dylib")
        XCTAssertEqual(try read(link), "shared")
        XCTAssertEqual(try read(root.appendingPathComponent("lib/external/D3DMetal.framework/D3DMetal")), "framework")

        let prefix = paths.root.appendingPathComponent("pfx")
        XCTAssertEqual(composed.missingPrefixDLLs(winePrefix: prefix), ["drive_c/windows/system32/d3d12.dll"])
    }
}
