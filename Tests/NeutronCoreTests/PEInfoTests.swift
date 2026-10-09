import XCTest
@testable import NeutronCore

final class PEInfoTests: XCTestCase {
    private func makePE() -> Data {
        Fixtures.makePE(imports: ["D3D11.dll"], delayImports: ["dxgi.dll"])
    }

    func testParsesImportsAndDelayImports() throws {
        let info = try PEInfo(data: makePE())
        XCTAssertEqual(info.machine, .x86_64)
        XCTAssertEqual(info.imports, ["d3d11.dll", "dxgi.dll"])
    }

    func testParsesExports() throws {
        let info = try PEInfo(data: Fixtures.makePE(imports: ["KERNEL32.dll"], exports: ["__wine_unix_call", "NtClose"]))
        XCTAssertEqual(info.exports, ["__wine_unix_call", "NtClose"])
        XCTAssertEqual(try PEInfo(data: makePE()).exports, [])
    }

    func testRejectsNonPE() {
        XCTAssertThrowsError(try PEInfo(data: Data("#!/bin/sh\n".utf8)))
    }

    func testRejectsTruncatedPE() {
        XCTAssertThrowsError(try PEInfo(data: makePE().prefix(0x50)))
    }
}
