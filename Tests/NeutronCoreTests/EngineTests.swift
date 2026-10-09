import XCTest
@testable import NeutronCore

final class EngineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("neutron-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A Unity game laid out like Berry Bounce: the renderer in UnityPlayer.dll, which (like
    /// many real builds) imports only opengl32 and loads D3D at runtime.
    private func makeUnityGame(version: String = "6000.3.0f1", agility: Bool) throws -> URL {
        let game = root.appendingPathComponent("Berry Bounce")
        let exe = game.appendingPathComponent("BerryBounce.exe")
        try Fixtures.write(exe, Fixtures.makePE(imports: ["KERNEL32.dll"]))
        try Fixtures.write(game.appendingPathComponent("UnityPlayer.dll"), Fixtures.makePE(imports: ["OPENGL32.dll"]))
        var header = Data(repeating: 0, count: 0x30)
        header.append(Data("\(version)\0".utf8))
        try Fixtures.write(game.appendingPathComponent("BerryBounce_Data/globalgamemanagers"), header)
        if agility { try Fixtures.write(game.appendingPathComponent("D3D12/D3D12Core.dll")) }
        return exe
    }

    /// An Unreal game with a stub launcher, like Deep Rock Galactic (`FSD.exe`).
    private func makeUnrealGame(stub: String = "FSD", shipping: String = "FSD-Win64-Shipping.exe",
                                engineFolder: Bool = true, agility: Bool = false) throws -> (stub: URL, shipping: URL) {
        let game = root.appendingPathComponent("Deep Rock Galactic")
        let stubURL = game.appendingPathComponent("\(stub).exe")
        try Fixtures.write(stubURL, Fixtures.makePE(imports: ["KERNEL32.dll"]))
        let binaries = game.appendingPathComponent("FSD/Binaries/Win64")
        var marker = Data(repeating: 0, count: 64)
        marker.append("++UE4+Release-4.27".data(using: .utf16LittleEndian)!)
        var shippingData = Fixtures.makePE(imports: ["d3d11.dll", "d3d12.dll", "dxgi.dll"])
        shippingData.append(marker)
        let shippingURL = binaries.appendingPathComponent(shipping)
        try Fixtures.write(shippingURL, shippingData)
        if engineFolder { try FileManager.default.createDirectory(at: game.appendingPathComponent("Engine/Binaries"), withIntermediateDirectories: true) }
        if agility { try Fixtures.write(binaries.appendingPathComponent("D3D12/x64/D3D12Core.dll")) }
        return (stubURL, shippingURL)
    }

    /// Unity's D3D12 renderer needs D3D11On12, which D3DMetal lacks, so even Unity 6 games
    /// that ship the Agility SDK go to DXMT.
    func testUnityWithAgilitySDKStillUsesDXMT() throws {
        let scan = try GameScan(executable: try makeUnityGame(agility: true))
        XCTAssertEqual(scan.engine?.engine, .unity(version: "6000.3.0f1"))
        XCTAssertEqual(scan.engine?.shipsD3D12AgilitySDK, true)
        XCTAssertEqual(scan.recommendation.backend, .dxmt)
        XCTAssertNil(scan.recommendation.fallback)
    }

    func testUnityWithoutAgilitySDKUsesDXMTEvenWithoutD3DImports() throws {
        let scan = try GameScan(executable: try makeUnityGame(version: "2019.4.29f1", agility: false))
        XCTAssertEqual(scan.engine?.engine, .unity(version: "2019.4.29f1"))
        XCTAssertEqual(scan.imports, ["kernel32.dll", "opengl32.dll"])
        XCTAssertEqual(scan.recommendation.backend, .dxmt)
        XCTAssertNil(scan.recommendation.fallback)
    }

    func testOldUnityFallsBackToImportRules() throws {
        XCTAssertFalse(GameEngine.unity(version: "4.7.2f1").supportsD3D11)
        XCTAssertTrue(GameEngine.unity(version: nil).supportsD3D11)
        let scan = try GameScan(executable: try makeUnityGame(version: "4.7.2f1", agility: false))
        XCTAssertEqual(scan.recommendation.backend, .wined3d)
    }

    func testUnrealStubFollowsShippingExecutable() throws {
        let game = try makeUnrealGame()
        let scan = try GameScan(executable: game.stub)
        XCTAssertEqual(scan.engine?.renderer.path, game.shipping.path)
        XCTAssertEqual(scan.engine?.engine, .unreal(version: "4.27"))
        XCTAssertTrue(scan.imports.contains("d3d12.dll"))
        XCTAssertEqual(scan.recommendation.backend, .dxmt)
    }

    func testUnrealAgilitySDKNextToShippingExe() throws {
        let scan = try GameScan(executable: try makeUnrealGame(agility: true).stub)
        XCTAssertEqual(scan.recommendation.backend, .d3dmetal)
        XCTAssertEqual(scan.recommendation.fallback, .dxmt)
    }

    func testUnrealStubNeedsNameMatchWithoutEngineFolder() throws {
        let unnamed = try makeUnrealGame(stub: "Launcher", engineFolder: false)
        XCTAssertNil(EngineDetection.detect(executable: unnamed.stub))
        // With Engine/ next to it, a lone Shipping exe is enough.
        try FileManager.default.createDirectory(at: unnamed.stub.deletingLastPathComponent().appendingPathComponent("Engine"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(EngineDetection.detect(executable: unnamed.stub)?.renderer.path, unnamed.shipping.path)
    }

    /// A Godot executable: the engine banner and URL live in the binary (no D3D imports).
    private func makeGodotGame(version: String) throws -> URL {
        let exe = root.appendingPathComponent("Fortune Mill/FortuneMill.exe")
        var data = Fixtures.makePE(imports: ["KERNEL32.dll"])
        data.append(Data("\0Godot Engine v\(version).stable.mono.official\0https://godotengine.org\0".utf8))
        try Fixtures.write(exe, data)
        return exe
    }

    func testGodot4UsesVulkanThroughMoltenVK() throws {
        let scan = try GameScan(executable: try makeGodotGame(version: "4.5.1"))
        XCTAssertEqual(scan.engine?.engine, .godot(version: "4.5.1"))
        XCTAssertEqual(scan.recommendation.backend, .wined3d)
        let godot = GameEngine.godot(version: "4.5.1")
        XCTAssertEqual(godot.arguments(for: .wined3d, userArguments: []), ["--rendering-driver", "vulkan"])
        XCTAssertEqual(godot.arguments(for: .d3dmetal, userArguments: []), [])
        XCTAssertEqual(godot.arguments(for: .wined3d, userArguments: ["--rendering-driver", "opengl3"]), [])
    }

    func testGodot3NeedsNoFlags() throws {
        let scan = try GameScan(executable: try makeGodotGame(version: "3.5.3"))
        XCTAssertEqual(scan.engine?.engine, .godot(version: "3.5.3"))
        XCTAssertEqual(GameEngine.godot(version: "3.5.3").arguments(for: .wined3d, userArguments: []), [])
        XCTAssertTrue(scan.recommendation.reason.contains("OpenGL"))
    }

    func testNonGodotExecutableIsNotGodot() throws {
        let exe = root.appendingPathComponent("Plain/game.exe")
        var data = Fixtures.makePE(imports: ["d3d11.dll"])
        data.append(Data("version 4.5.1.stable but no engine URL".utf8))
        try Fixtures.write(exe, data)
        XCTAssertNil(EngineDetection.godotVersion(executable: exe))
        XCTAssertNil(try GameScan(executable: exe).engine)
    }

    func testEngineArguments() {
        let unity = GameEngine.unity(version: "2022.3.1f1")
        XCTAssertEqual(unity.arguments(for: .dxmt, userArguments: []), ["-force-d3d11"])
        XCTAssertEqual(unity.arguments(for: .wined3d, userArguments: []), ["-force-d3d11"])
        XCTAssertEqual(unity.arguments(for: .d3dmetal, userArguments: []), [])
        XCTAssertEqual(unity.arguments(for: .dxmt, userArguments: ["-Force-D3D12"]), [])
        XCTAssertEqual(GameEngine.unreal(version: nil).arguments(for: .dxmt, userArguments: ["-windowed"]), ["-dx11"])
    }

    func testMiddlewareDLLsDontForceD3D12() throws {
        let game = root.appendingPathComponent("Dark Deity")
        let exe = game.appendingPathComponent("DarkDeity.exe")
        try Fixtures.write(exe, Fixtures.makePE(imports: ["d3d11.dll", "dxgi.dll"]))
        try Fixtures.write(game.appendingPathComponent("EOSSDK-Win64-Shipping.dll"), Fixtures.makePE(imports: ["d3d12.dll"]))
        let scan = try GameScan(executable: exe)
        XCTAssertNil(scan.engine)
        XCTAssertEqual(scan.recommendation.backend, .dxmt)
    }

    func testLauncherFallsBackAndAddsEngineFlag() throws {
        let paths = NeutronPaths(root: root.appendingPathComponent("state"))
        let runtimes = RuntimeStore(paths: paths)
        let wine = paths.root.appendingPathComponent("builds/wine")
        try Fixtures.write(wine.appendingPathComponent("bin/wine"))
        try runtimes.add(kind: .wine, path: wine)
        let dxmt = paths.root.appendingPathComponent("builds/dxmt")
        try Fixtures.write(dxmt.appendingPathComponent("x86_64-windows/d3d11.dll"))
        try runtimes.add(kind: .dxmt, path: dxmt)
        let prefix = try PrefixStore(paths: paths).create(PrefixConfig(name: "default"))
        var launcher = Launcher(runtimes: runtimes)
        launcher.capabilities = { _ in WineCapabilities(exportsMacDriverFunctions: true, exportsWineUnixCall: true) }
        let exe = try makeUnrealGame(agility: true).stub

        // No GPTK registered: falls back from d3dmetal to dxmt and forces D3D11.
        let plan = try launcher.gamePlan(prefix: prefix, program: exe, arguments: ["-windowed"], options: LaunchOptions())
        XCTAssertEqual(plan.backend, .dxmt)
        XCTAssertEqual(plan.arguments, [exe.path, "-dx11", "-windowed"])
        XCTAssertEqual(plan.notes.count, 2)

        // An explicit backend still gets the engine flag; --no-engine-args turns it off.
        let explicit = try launcher.gamePlan(prefix: prefix, program: exe, options: LaunchOptions(backend: .dxmt))
        XCTAssertEqual(explicit.arguments, [exe.path, "-dx11"])
        let plain = try launcher.gamePlan(prefix: prefix, program: exe,
                                          options: LaunchOptions(backend: .dxmt, engineArguments: false))
        XCTAssertEqual(plain.arguments, [exe.path])

        // Without GPTK or a fallback, d3dmetal reports the missing runtime.
        XCTAssertThrowsError(try launcher.gamePlan(prefix: prefix, program: exe, options: LaunchOptions(backend: .d3dmetal)))
    }

    /// GPTK is registered, but this Wine can't run D3DMetal (Wine 10+): auto falls back to DXMT;
    /// an explicit choice is kept with a warning.
    func testWineCapabilitiesSteerBackendChoice() throws {
        let paths = NeutronPaths(root: root.appendingPathComponent("state"))
        let runtimes = RuntimeStore(paths: paths)
        let wine = paths.root.appendingPathComponent("builds/wine")
        try Fixtures.write(wine.appendingPathComponent("bin/wine"))
        try runtimes.add(kind: .wine, path: wine)
        let dxmt = paths.root.appendingPathComponent("builds/dxmt")
        try Fixtures.write(dxmt.appendingPathComponent("x86_64-windows/d3d11.dll"))
        try runtimes.add(kind: .dxmt, path: dxmt)
        let gptk = paths.root.appendingPathComponent("builds/gptk")
        try Fixtures.write(gptk.appendingPathComponent("redist/lib/external/D3DMetal.framework/D3DMetal"))
        try runtimes.add(kind: .gptk, path: gptk)
        let prefix = try PrefixStore(paths: paths).create(PrefixConfig(name: "default"))
        var launcher = Launcher(runtimes: runtimes)
        launcher.capabilities = { _ in WineCapabilities(exportsMacDriverFunctions: true, exportsWineUnixCall: false) }
        let exe = try makeUnrealGame(agility: true).stub

        let auto = try launcher.gamePlan(prefix: prefix, program: exe, options: LaunchOptions())
        XCTAssertEqual(auto.backend, .dxmt)
        XCTAssertTrue(auto.notes[0].contains("__wine_unix_call"), auto.notes[0])

        let explicit = try launcher.gamePlan(prefix: prefix, program: exe, options: LaunchOptions(backend: .d3dmetal))
        XCTAssertEqual(explicit.backend, .d3dmetal)
        XCTAssertTrue(explicit.notes.contains { $0.hasPrefix("warning:") })

        // A Wine that can run both keeps d3dmetal.
        launcher.capabilities = { _ in WineCapabilities(exportsMacDriverFunctions: true, exportsWineUnixCall: true) }
        XCTAssertEqual(try launcher.gamePlan(prefix: prefix, program: exe, options: LaunchOptions()).backend, .d3dmetal)
    }
}
