import XCTest
@testable import NeutronCore

final class StoreTests: XCTestCase {
    private var paths: NeutronPaths!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neutron-tests-\(UUID().uuidString)")
        paths = NeutronPaths(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: paths.root)
    }

    /// A fake Wine build: just an executable at bin/wine.
    private func makeWine(_ version: String) throws -> URL {
        let root = paths.root.appendingPathComponent("builds/\(version)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let wine = bin.appendingPathComponent("wine")
        try Data().write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        return root
    }

    func testPrefixRoundTrip() throws {
        let store = PrefixStore(paths: paths)
        var prefix = try store.create(PrefixConfig(name: "steam", backend: .dxmt))
        prefix.config.environment["DXMT_LOG_LEVEL"] = "info"
        try store.save(prefix)

        let loaded = try store.get("steam")
        XCTAssertEqual(loaded.config, prefix.config)
        XCTAssertEqual(try store.list().map(\.config.name), ["steam"])
        XCTAssertThrowsError(try store.create(PrefixConfig(name: "steam")))

        try store.delete("steam")
        XCTAssertThrowsError(try store.get("steam"))
    }

    func testRejectsBadPrefixNames() {
        let store = PrefixStore(paths: paths)
        for name in ["", ".hidden", "../escape", "a/b"] {
            XCTAssertThrowsError(try store.create(PrefixConfig(name: name)), name)
        }
    }

    func testRuntimeFindPicksNewestVersion() throws {
        let store = RuntimeStore(paths: paths)
        try store.add(kind: .wine, path: makeWine("9.0"))
        try store.add(kind: .wine, path: makeWine("10.2"))
        XCTAssertEqual(try store.find(.wine).version, "10.2")
        XCTAssertEqual(try store.find(.wine, version: "9.0").version, "9.0")
        XCTAssertThrowsError(try store.find(.dxmt))
    }

    func testLaunchPlanEnvironment() throws {
        let runtimes = RuntimeStore(paths: paths)
        try runtimes.add(kind: .wine, path: makeWine("10.2"))
        let prefix = try PrefixStore(paths: paths).create(
            PrefixConfig(name: "default", environment: ["WINEDLLOVERRIDES": "xinput1_3=n,b", "WINEDEBUG": "+err"])
        )
        let plan = try Launcher(runtimes: runtimes).winePlan(
            prefix: prefix, arguments: ["winecfg"], options: LaunchOptions(hud: true),
            setup: try BackendSetup.make(for: .wined3d, runtime: nil)
        )
        XCTAssertEqual(plan.environment["WINEPREFIX"], prefix.winePrefix.path)
        XCTAssertEqual(plan.environment["WINEDEBUG"], "+err")
        XCTAssertEqual(plan.environment["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(plan.environment["WINEDLLOVERRIDES"], "d3d10core=b;d3d11=b;dxgi=b;xinput1_3=n,b")
        XCTAssertEqual(plan.executable.lastPathComponent, "wine")
    }
}
