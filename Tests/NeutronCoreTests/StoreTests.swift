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

    /// Writes an empty file, creating parent directories.
    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
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
        XCTAssertEqual(plan.environment["MVK_CONFIG_LOG_LEVEL"], "1")
        XCTAssertEqual(plan.executable.lastPathComponent, "wine")
        XCTAssertNil(plan.composition)
    }

    func testKillPlanUsesPrefixWineserverAndEnvironment() throws {
        let runtimes = RuntimeStore(paths: paths)
        let frameworks = paths.root.appendingPathComponent("Frameworks")
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try runtimes.add(kind: .wine, path: makeWine("cx24"), libraryPaths: [frameworks])
        let prefix = try PrefixStore(paths: paths).create(PrefixConfig(name: "steam"))
        let plan = try Launcher(runtimes: runtimes).killPlan(prefix: prefix)
        XCTAssertEqual(plan.executable.path, paths.root.appendingPathComponent("builds/cx24/bin/wineserver").path)
        XCTAssertEqual(plan.arguments, ["-k"])
        XCTAssertEqual(plan.environment["WINEPREFIX"], prefix.winePrefix.path)
        XCTAssertEqual(plan.environment["DYLD_FALLBACK_LIBRARY_PATH"], frameworks.path)
        XCTAssertNil(plan.composition)
    }

    func testDXMTPlanUsesComposedWine() throws {
        let runtimes = RuntimeStore(paths: paths)
        try runtimes.add(kind: .wine, path: makeWine("10.2"))
        let dxmtRoot = paths.root.appendingPathComponent("builds/dxmt-v0.80")
        try touch(dxmtRoot.appendingPathComponent("x86_64-windows/d3d11.dll"))
        try runtimes.add(kind: .dxmt, path: dxmtRoot)
        let prefix = try PrefixStore(paths: paths).create(PrefixConfig(name: "default"))

        let plan = try Launcher(runtimes: runtimes).gamePlan(
            prefix: prefix, program: URL(fileURLWithPath: "/games/Game/game.exe"),
            options: LaunchOptions(backend: .dxmt)
        )
        let composed = paths.composed.appendingPathComponent("10.2+dxmt-dxmt-v0.80")
        XCTAssertEqual(plan.composition?.path.path, composed.path)
        XCTAssertEqual(plan.executable, composed.appendingPathComponent("bin/wine"))
        XCTAssertNil(plan.environment["WINEDLLPATH"])
        XCTAssertEqual(plan.environment["WINEDLLOVERRIDES"], "d3d10core=b;d3d11=b;dxgi=b;winemetal=b")
        XCTAssertEqual(plan.workingDirectory?.path, "/games/Game")
        XCTAssertEqual(plan.backend, .dxmt)
    }

    func testWineLibraryPathsBecomeDyldFallback() throws {
        let runtimes = RuntimeStore(paths: paths)
        let frameworks = paths.root.appendingPathComponent("Template.app/Contents/Frameworks")
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try runtimes.add(kind: .wine, path: makeWine("cx24"), libraryPaths: [frameworks])
        XCTAssertEqual(try runtimes.find(.wine).libraryPaths?.map(\.path), [frameworks.path])
        XCTAssertThrowsError(try runtimes.add(kind: .wine, path: makeWine("cx25"),
                                              libraryPaths: [paths.root.appendingPathComponent("missing")]))

        let prefixes = PrefixStore(paths: paths)
        let plain = try prefixes.create(PrefixConfig(name: "plain"))
        let launcher = Launcher(runtimes: runtimes)
        let plan = try launcher.winePlan(prefix: plain, arguments: ["winecfg"], options: LaunchOptions())
        XCTAssertEqual(plan.environment["DYLD_FALLBACK_LIBRARY_PATH"], frameworks.path)

        let custom = try prefixes.create(PrefixConfig(name: "custom", environment: ["DYLD_FALLBACK_LIBRARY_PATH": "/x"]))
        XCTAssertEqual(try launcher.winePlan(prefix: custom, arguments: [], options: LaunchOptions())
            .environment["DYLD_FALLBACK_LIBRARY_PATH"], "/x")
    }

    /// `--gstreamer` takes the official framework; the plan finds its libraries and plugins,
    /// keeps the plugin registry under Neutron's state and pre-scans it with gst-inspect.
    func testGStreamerEnvironment() throws {
        let framework = paths.root.appendingPathComponent("Frameworks/GStreamer.framework")
        let version = framework.appendingPathComponent("Versions/1.0")
        try touch(version.appendingPathComponent("lib/libgstreamer-1.0.0.dylib"))
        try touch(version.appendingPathComponent("lib/gstreamer-1.0/libgstapp.dylib"))
        try FileManager.default.createSymbolicLink(at: framework.appendingPathComponent("Versions/Current"),
                                                   withDestinationURL: version)
        let frameworks = paths.root.appendingPathComponent("Template/Frameworks")
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)

        let runtimes = RuntimeStore(paths: paths)
        XCTAssertThrowsError(try runtimes.add(kind: .wine, path: makeWine("bad"), gstreamer: frameworks)) {
            XCTAssertEqual($0 as? NeutronError, .invalidGStreamer(frameworks.path))
        }
        try runtimes.add(kind: .wine, path: makeWine("11.18"), libraryPaths: [frameworks], gstreamer: framework)
        let root = version.resolvingSymlinksInPath()
        XCTAssertEqual(try runtimes.find(.wine).gstreamer?.path, root.path)

        let prefix = try PrefixStore(paths: paths).create(PrefixConfig(name: "video"))
        let env = try Launcher(runtimes: runtimes).winePlan(prefix: prefix, arguments: [], options: LaunchOptions()).environment
        XCTAssertEqual(env["DYLD_FALLBACK_LIBRARY_PATH"], "\(frameworks.path):\(root.path)/lib")
        XCTAssertEqual(env["GST_PLUGIN_SYSTEM_PATH_1_0"], "\(root.path)/lib/gstreamer-1.0")
        XCTAssertEqual(env["GST_REGISTRY_1_0"], paths.runtimes.appendingPathComponent("gstreamer/11.18.bin").path)
        XCTAssertNil(env["GST_REGISTRY_FORK"])
        XCTAssertNil(try Launcher(runtimes: runtimes).winePlan(prefix: prefix, arguments: [], options: LaunchOptions()).gstreamerScan)

        // With gst-inspect in the install, it pre-scans plugins natively (not for `kill`).
        let inspect = root.appendingPathComponent("bin/gst-inspect-1.0")
        try touch(inspect)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inspect.path)
        let launcher = Launcher(runtimes: runtimes)
        XCTAssertEqual(try launcher.winePlan(prefix: prefix, arguments: [], options: LaunchOptions()).gstreamerScan, inspect)
        XCTAssertNil(try launcher.killPlan(prefix: prefix).gstreamerScan)
    }

    /// Release archives extract into a wrapper folder; `runtime add` should look inside it.
    func testRuntimeRootFoundInsideWrapperFolder() throws {
        let wineWrapper = paths.root.appendingPathComponent("dl/wine-devel-11.18")
        let app = wineWrapper.appendingPathComponent("Wine Devel.app")
        try touch(app.appendingPathComponent("Contents/Resources/wine/bin/wine"))
        XCTAssertEqual(try Runtime.resolveRoot(kind: .wine, at: wineWrapper).path,
                       app.appendingPathComponent("Contents/Resources/wine").path)

        let dxmtWrapper = paths.root.appendingPathComponent("dl/dxmt-v0.80")
        try touch(dxmtWrapper.appendingPathComponent("v0.80/x86_64-windows/d3d11.dll"))
        XCTAssertEqual(try Runtime.resolveRoot(kind: .dxmt, at: dxmtWrapper).path,
                       dxmtWrapper.appendingPathComponent("v0.80").path)

        XCTAssertThrowsError(try Runtime.resolveRoot(kind: .gptk, at: dxmtWrapper))
    }

    func testDefaultVersionFromAppBundle() throws {
        let app = paths.root.appendingPathComponent("Wine Devel.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleShortVersionString": "11.18"]
        XCTAssertTrue(info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true))
        XCTAssertEqual(Runtime.defaultVersion(for: app), "wine-devel-11.18")
        XCTAssertEqual(Runtime.defaultVersion(for: URL(fileURLWithPath: "/dl/dxmt-v0.80")), "dxmt-v0.80")
    }
}
