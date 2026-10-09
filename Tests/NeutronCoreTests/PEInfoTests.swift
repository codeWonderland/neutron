import XCTest
@testable import NeutronCore

final class PEInfoTests: XCTestCase {
    /// Builds a minimal PE32+ image: one section holding an import table (D3D11.dll)
    /// and a delay-import table (dxgi.dll).
    private func makePE() -> Data {
        var b = [UInt8](repeating: 0, count: 0x400)
        func put16(_ o: Int, _ v: UInt16) { for i in 0..<2 { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
        func put32(_ o: Int, _ v: UInt32) { for i in 0..<4 { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
        func put64(_ o: Int, _ v: UInt64) { for i in 0..<8 { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
        func putString(_ o: Int, _ s: String) { for (i, c) in s.utf8.enumerated() { b[o + i] = c } }

        put16(0, 0x5A4D)                 // MZ
        put32(0x3C, 0x40)                // e_lfanew
        put32(0x40, 0x0000_4550)         // PE\0\0
        let coff = 0x44
        put16(coff, 0x8664)              // x86_64
        put16(coff + 2, 1)               // one section
        put16(coff + 16, 240)            // optional header size (PE32+)
        let opt = coff + 20
        put16(opt, 0x20B)                // PE32+
        put64(opt + 24, 0x1_4000_0000)   // image base
        put32(opt + 108, 16)             // data directory count
        put32(opt + 112 + 1 * 8, 0x1000) // import table RVA
        put32(opt + 112 + 13 * 8, 0x1100) // delay-import table RVA

        let section = opt + 240
        put32(section + 8, 0x1000)       // virtual size
        put32(section + 12, 0x1000)      // virtual address
        put32(section + 16, 0x200)       // raw size
        put32(section + 20, 0x200)       // raw pointer

        put32(0x200 + 12, 0x1080)        // import descriptor: name RVA
        put32(0x200 + 16, 0x1090)        // import descriptor: first thunk
        put32(0x300, 1)                  // delay descriptor: RVA-based
        put32(0x300 + 4, 0x10A0)         // delay descriptor: name RVA
        putString(0x280, "D3D11.dll")
        putString(0x2A0, "dxgi.dll")
        return Data(b)
    }

    func testParsesImportsAndDelayImports() throws {
        let info = try PEInfo(data: makePE())
        XCTAssertEqual(info.machine, .x86_64)
        XCTAssertEqual(info.imports, ["d3d11.dll", "dxgi.dll"])
    }

    func testRejectsNonPE() {
        XCTAssertThrowsError(try PEInfo(data: Data("#!/bin/sh\n".utf8)))
    }

    func testRejectsTruncatedPE() {
        XCTAssertThrowsError(try PEInfo(data: makePE().prefix(0x50)))
    }
}
