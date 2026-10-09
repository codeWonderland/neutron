import XCTest
@testable import NeutronCore

final class WineCapabilitiesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("neutron-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A minimal 64-bit Mach-O with an LC_DYLD_EXPORTS_TRIE exporting `symbols`, each as its
    /// own edge from the root node.
    private func makeMachO(exporting symbols: [String]) -> Data {
        // Trie: root (no terminal) with one child per symbol; each child is a terminal node.
        var trie: [UInt8] = [0, UInt8(symbols.count)]
        let edgesSize = symbols.reduce(0) { $0 + $1.utf8.count + 1 + 1 }
        var childOffset = 2 + edgesSize
        var children: [UInt8] = []
        for symbol in symbols {
            trie += Array(symbol.utf8) + [0, UInt8(childOffset)]
            let node: [UInt8] = [2, 0, 0, 0]   // terminal size 2 (flags, address), no children
            children += node
            childOffset += node.count
        }
        trie += children

        var b = [UInt8](repeating: 0, count: 0x100)
        func put32(_ o: Int, _ v: UInt32) { for i in 0..<4 { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
        put32(0, 0xFEED_FACF)                // MH_MAGIC_64
        put32(16, 1)                         // one load command
        put32(32, 0x8000_0033)               // LC_DYLD_EXPORTS_TRIE
        put32(36, 16)
        put32(40, 0x80)                      // dataoff
        put32(44, UInt32(trie.count))        // datasize
        for (i, byte) in trie.enumerated() { b[0x80 + i] = byte }
        return Data(b)
    }

    private func makeWine(winemacExports: [String], ntdllExports: [String]) throws -> Runtime {
        let wine = root.appendingPathComponent("wine")
        try Fixtures.write(wine.appendingPathComponent("lib/wine/x86_64-unix/winemac.so"), makeMachO(exporting: winemacExports))
        try Fixtures.write(wine.appendingPathComponent("lib/wine/x86_64-windows/ntdll.dll"),
                           Fixtures.makePE(imports: [], exports: ntdllExports))
        return Runtime(kind: .wine, version: "test", path: wine)
    }

    func testStockWine() throws {
        let caps = WineCapabilities(wine: try makeWine(winemacExports: ["___wine_unix_call_funcs"],
                                                       ntdllExports: ["__wine_unix_call_dispatcher"]))
        XCTAssertFalse(caps.exportsMacDriverFunctions)
        XCTAssertFalse(caps.exportsWineUnixCall)
        XCTAssertTrue(caps.supports(.wined3d))
        XCTAssertFalse(caps.supports(.dxmt))
        XCTAssertNotNil(caps.problem(with: .dxmt))
    }

    func testCrossOverStyleWine() throws {
        let caps = WineCapabilities(wine: try makeWine(winemacExports: ["___wine_unix_call_funcs", "_macdrv_functions"],
                                                       ntdllExports: ["__wine_unix_call", "__wine_unix_call_dispatcher"]))
        XCTAssertTrue(caps.supports(.dxmt))
        XCTAssertTrue(caps.supports(.d3dmetal))
        XCTAssertNil(caps.problem(with: .d3dmetal))
    }

    func testPrefixOfExportIsNotAMatch() throws {
        let caps = WineCapabilities(wine: try makeWine(winemacExports: ["_macdrv_functions_v2"], ntdllExports: []))
        XCTAssertFalse(caps.exportsMacDriverFunctions)
    }
}
