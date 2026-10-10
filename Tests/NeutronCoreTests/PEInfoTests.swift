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

    func testReadsCLRFlags() throws {
        XCTAssertNil(try PEInfo(data: makePE()).clrFlags)
        XCTAssertFalse(try PEInfo(data: makePE()).isDotNet32BitOnly)
        // XNA games: 32-bit, IL-only + 32BITREQUIRED (Secrets of Grindea has flags 0x3).
        let xna = try PEInfo(data: Fixtures.makePE(imports: ["mscoree.dll"], machine: 0x14C, clrFlags: 0x3))
        XCTAssertEqual(xna.clrFlags, 0x3)
        XCTAssertTrue(xna.isDotNet32BitOnly)
        // Mixed-mode (not IL-only) 32-bit assemblies are 32-bit too.
        XCTAssertTrue(try PEInfo(data: Fixtures.makePE(imports: ["mscoree.dll"], machine: 0x14C, clrFlags: 0x0)).isDotNet32BitOnly)
        // AnyCPU (32-bit image, IL-only) runs as 64-bit; so do 64-bit images.
        XCTAssertFalse(try PEInfo(data: Fixtures.makePE(imports: ["mscoree.dll"], machine: 0x14C, clrFlags: 0x1)).isDotNet32BitOnly)
        XCTAssertFalse(try PEInfo(data: Fixtures.makePE(imports: ["mscoree.dll"], clrFlags: 0x3)).isDotNet32BitOnly)
    }

    func testRejectsNonPE() {
        XCTAssertThrowsError(try PEInfo(data: Data("#!/bin/sh\n".utf8)))
    }

    func testRejectsTruncatedPE() {
        XCTAssertThrowsError(try PEInfo(data: makePE().prefix(0x50)))
    }
}
