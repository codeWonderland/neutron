import XCTest
@testable import NeutronCore

final class LaunchLogTests: XCTestCase {
    private var paths: NeutronPaths!

    override func setUpWithError() throws {
        paths = NeutronPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("neutron-tests-\(UUID().uuidString)"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: paths.root)
    }

    func testLogNaming() {
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour, components.minute, components.second) = (2026, 10, 8, 23, 5, 9)
        let date = Calendar.current.date(from: components)!
        let url = LaunchLog.url(paths: paths, prefix: "steam", program: URL(fileURLWithPath: "/g/Loop Tower Demo.exe"), date: date)
        XCTAssertEqual(url.deletingLastPathComponent().path, paths.logs.appendingPathComponent("steam").path)
        XCTAssertEqual(url.lastPathComponent, "20261008-230509-Loop-Tower-Demo.log")
    }

    func testPruneKeepsNewest() throws {
        let directory = paths.logs.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for day in 1...5 { try Data().write(to: directory.appendingPathComponent("2026100\(day)-120000-game.log")) }
        try Data().write(to: directory.appendingPathComponent("notes.txt"))
        LaunchLog.prune(directory: directory, keep: 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       ["20261004-120000-game.log", "20261005-120000-game.log", "notes.txt"])
    }

    /// Both output streams land in the log, after a header that records the command.
    func testRunWritesHeaderAndOutput() throws {
        let plan = LaunchPlan(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo to-stdout; echo to-stderr >&2; exit 3"],
                              environment: ["NEUTRON_TEST": "1"], workingDirectory: nil, backend: .dxmt,
                              composition: nil, prefixName: "p", winePrefix: paths.root)
        let log = paths.logs.appendingPathComponent("p/test.log")
        let status = try Launcher(runtimes: RuntimeStore(paths: paths)).run(plan, log: log)
        XCTAssertEqual(status, 3)
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# Neutron launch, "), text)
        XCTAssertTrue(text.contains("# backend: dxmt"))
        XCTAssertTrue(text.contains("# env NEUTRON_TEST=1"))
        XCTAssertTrue(text.contains("# /bin/sh -c"))
        XCTAssertTrue(text.contains("to-stdout\n"))
        XCTAssertTrue(text.contains("to-stderr\n"))
    }
}
