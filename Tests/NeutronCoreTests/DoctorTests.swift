import XCTest
@testable import NeutronCore

final class DoctorTests: XCTestCase {
    private var paths: NeutronPaths!

    override func setUpWithError() throws {
        paths = NeutronPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("neutron-tests-\(UUID().uuidString)"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: paths.root)
    }

    private let goodHost = Doctor.Host(macOSVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 5, patchVersion: 0),
                                       isAppleSilicon: true, rosettaInstalled: true)

    private func checks(host: Doctor.Host? = nil, caps: WineCapabilities = WineCapabilities(exportsMacDriverFunctions: true, exportsWineUnixCall: false)) -> [Doctor.Check] {
        Doctor.checks(host: host ?? goodHost, runtimes: RuntimeStore(paths: paths), prefixes: PrefixStore(paths: paths),
                      capabilities: { _ in caps })
    }

    private func titles(_ checks: [Doctor.Check], _ status: Doctor.Check.Status) -> [String] {
        checks.filter { $0.status == status }.map(\.title)
    }

    /// A thin 64-bit Mach-O whose only load command is LC_LOAD_DYLIB of `dylib`.
    private func makeMachO(loading dylib: String) -> Data {
        var b = [UInt8](repeating: 0, count: 0x100)
        func put32(_ o: Int, _ v: UInt32) { for i in 0..<4 { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
        put32(0, 0xFEED_FACF)
        put32(16, 1)
        put32(32, 0xC)          // LC_LOAD_DYLIB
        put32(36, 0x80)         // cmdsize
        put32(40, 24)           // name offset
        for (i, c) in dylib.utf8.enumerated() { b[32 + 24 + i] = c }
        return Data(b)
    }

    private func addWine(_ version: String, libraryPaths: [URL] = [], needs dylib: String? = nil,
                         winegstreamer: Bool = false, gstreamer: URL? = nil) throws {
        let root = paths.root.appendingPathComponent("builds/\(version)")
        try Fixtures.write(root.appendingPathComponent("bin/wine"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("bin/wine").path)
        if let dylib { try Fixtures.write(root.appendingPathComponent("bin/wineserver"), makeMachO(loading: "@rpath/\(dylib)")) }
        if winegstreamer {
            try Fixtures.write(root.appendingPathComponent("lib/wine/x86_64-unix/winegstreamer.so"),
                               makeMachO(loading: "@rpath/libgstreamer-1.0.0.dylib"))
        }
        try RuntimeStore(paths: paths).add(kind: .wine, path: root, version: version, libraryPaths: libraryPaths,
                                           gstreamer: gstreamer)
    }

    func testHostProblems() {
        let bad = Doctor.Host(macOSVersion: OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 1),
                              isAppleSilicon: false, rosettaInstalled: false)
        let failures = titles(checks(host: bad), .failure)
        XCTAssertTrue(failures.contains("macOS 13.6.1"))
        XCTAssertTrue(failures.contains("Not an Apple Silicon Mac"))
        XCTAssertTrue(failures.contains("Rosetta 2 not installed"))
        XCTAssertTrue(failures.contains("No Wine registered"))
    }

    func testWineThatCantPresentDXMT() throws {
        try addWine("11.18")
        let dxmt = paths.root.appendingPathComponent("builds/dxmt")
        try Fixtures.write(dxmt.appendingPathComponent("x86_64-windows/d3d11.dll"))
        try RuntimeStore(paths: paths).add(kind: .dxmt, path: dxmt)
        let result = checks(caps: WineCapabilities(exportsMacDriverFunctions: false, exportsWineUnixCall: false))
        let warnings = titles(result, .warning)
        XCTAssertTrue(warnings.contains { $0.hasPrefix("wine 11.18: DXMT no, D3DMetal no, msync no, wow64") }, "\(warnings)")
        XCTAssertTrue(warnings.contains { $0.hasPrefix("No registered Wine can present DXMT frames") })
        XCTAssertTrue(titles(checks(), .ok).contains { $0.hasPrefix("wine 11.18: DXMT yes") })
    }

    func testMissingWrapperLibraries() throws {
        try addWine("cx24", needs: "libinotify.0.dylib")
        XCTAssertTrue(titles(checks(), .failure).contains { $0.contains("needs libraries it doesn't ship (libinotify.0.dylib)") })

        let frameworks = paths.root.appendingPathComponent("Template.app/Contents/Frameworks")
        try Fixtures.write(frameworks.appendingPathComponent("libinotify.0.dylib"))
        try addWine("cx24-ok", libraryPaths: [frameworks], needs: "libinotify.0.dylib")
        XCTAssertFalse(titles(checks(), .failure).contains { $0.hasPrefix("wine cx24-ok") })
    }

    func testGStreamer() throws {
        try addWine("plain")
        try addWine("novideo", winegstreamer: true)
        let gstreamer = paths.root.appendingPathComponent("GStreamer")
        try Fixtures.write(gstreamer.appendingPathComponent("lib/libgstreamer-1.0.0.dylib"))
        try Fixtures.write(gstreamer.appendingPathComponent("lib/gstreamer-1.0/libgstapp.dylib"))
        try addWine("video", winegstreamer: true, gstreamer: gstreamer)
        var warnings = titles(checks(), .warning)
        XCTAssertTrue(warnings.contains("wine novideo: no GStreamer, so in-game videos won't play"), "\(warnings)")
        XCTAssertFalse(warnings.contains("wine plain: no GStreamer, so in-game videos won't play"))
        XCTAssertFalse(warnings.contains("wine video: no GStreamer, so in-game videos won't play"))

        try FileManager.default.removeItem(at: gstreamer)
        warnings = titles(checks(), .failure)
        XCTAssertTrue(warnings.contains("wine video: GStreamer at \(gstreamer.path) is missing"), "\(warnings)")
    }

    func testRuntimeMovedAndPrefixProblems() throws {
        try addWine("10.0")
        try FileManager.default.removeItem(at: paths.root.appendingPathComponent("builds/10.0"))
        let store = PrefixStore(paths: paths)
        _ = try store.create(PrefixConfig(name: "pinned", wineVersion: "9.0"))
        _ = try store.create(PrefixConfig(name: "fresh"))
        let result = checks()
        XCTAssertTrue(titles(result, .failure).contains { $0.hasPrefix("wine 10.0: missing or broken") })
        XCTAssertTrue(titles(result, .failure).contains("prefix pinned: pinned Wine 9.0 isn't registered"))
        XCTAssertTrue(titles(result, .warning).contains("prefix fresh: not initialized"))
    }
}
