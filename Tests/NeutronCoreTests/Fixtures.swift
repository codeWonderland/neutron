import Foundation

enum Fixtures {
    /// Builds a minimal PE32+ image with one section holding an import table (`imports`),
    /// a delay-import table (`delayImports`), up to 4 names in total, and an export table
    /// (`exports`, up to 8 names).
    static func makePE(imports: [String], delayImports: [String] = [], exports: [String] = []) -> Data {
        precondition(imports.count + delayImports.count <= 4 && exports.count <= 8)
        var b = [UInt8](repeating: 0, count: 0x600)
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
        if !imports.isEmpty { put32(opt + 112 + 1 * 8, 0x1000) }       // import table RVA
        if !delayImports.isEmpty { put32(opt + 112 + 13 * 8, 0x1100) } // delay-import table RVA
        if !exports.isEmpty { put32(opt + 112, 0x1200) }                 // export table RVA

        let section = opt + 240
        put32(section + 8, 0x1000)       // virtual size
        put32(section + 12, 0x1000)      // virtual address
        put32(section + 16, 0x400)       // raw size
        put32(section + 20, 0x200)       // raw pointer

        // Names live at file 0x280 + 0x20 * n (RVA 0x1080 + 0x20 * n).
        for (n, name) in (imports + delayImports).enumerated() { putString(0x280 + 0x20 * n, name) }
        for (n, _) in imports.enumerated() {
            put32(0x200 + 20 * n + 12, UInt32(0x1080 + 0x20 * n)) // import descriptor: name RVA
            put32(0x200 + 20 * n + 16, 0x1090)                    // first thunk (unused)
        }
        for (n, _) in delayImports.enumerated() {
            put32(0x300 + 32 * n, 1)                                                  // RVA-based
            put32(0x300 + 32 * n + 4, UInt32(0x1080 + 0x20 * (imports.count + n)))   // name RVA
        }
        // Export directory at file 0x400 (RVA 0x1200); name pointers at 0x430, names at 0x480.
        put32(0x400 + 24, UInt32(exports.count))
        put32(0x400 + 32, 0x1230)
        for (n, name) in exports.enumerated() {
            put32(0x430 + 4 * n, UInt32(0x1280 + 0x20 * n))
            putString(0x480 + 0x20 * n, name)
        }
        return Data(b)
    }

    /// Writes `data` (empty by default) to `url`, creating parent directories.
    static func write(_ url: URL, _ data: Data = Data()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
