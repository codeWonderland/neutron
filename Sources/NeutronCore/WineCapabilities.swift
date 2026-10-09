import Foundation

/// What a Wine build can do for each graphics backend, read from its files.
///
/// Phase 0 found two hard requirements that vary between builds:
/// - DXMT presents through `macdrv_functions` exported by `winemac.so`. Stock Wine keeps it
///   private, so DXMT creates a device but every frame fails (CrossOver-based builds and
///   `tools/wine-dxmt` export it).
/// - D3DMetal's DLLs import `__wine_unix_call` from `ntdll.dll`, which Wine 10+ dropped,
///   and they also need its old thread-register handling, so it only runs on CrossOver-era
///   builds (verified with Sikarugir's CrossOver 24 engine; crashes on Wine 11.18).
public struct WineCapabilities: Equatable, Sendable {
    public let exportsMacDriverFunctions: Bool
    public let exportsWineUnixCall: Bool

    public init(exportsMacDriverFunctions: Bool, exportsWineUnixCall: Bool) {
        self.exportsMacDriverFunctions = exportsMacDriverFunctions
        self.exportsWineUnixCall = exportsWineUnixCall
    }

    public init(wine: Runtime) {
        let lib = wine.path.appendingPathComponent("lib/wine")
        let winemac = ["x86_64-unix/winemac.so", "x86_64-unix/winemac.drv.so"]
            .map { lib.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        exportsMacDriverFunctions = winemac.map { MachOExports.contains("_macdrv_functions", in: $0) } ?? false
        let ntdll = lib.appendingPathComponent("x86_64-windows/ntdll.dll")
        exportsWineUnixCall = (try? PEInfo(contentsOf: ntdll))?.exports.contains("__wine_unix_call") ?? false
    }

    public func supports(_ backend: GraphicsBackend) -> Bool {
        switch backend {
        case .wined3d: return true
        case .dxmt: return exportsMacDriverFunctions
        case .d3dmetal: return exportsMacDriverFunctions && exportsWineUnixCall
        }
    }

    /// Why `backend` won't work on this Wine, for messages; nil when it should.
    public func problem(with backend: GraphicsBackend) -> String? {
        switch backend {
        case .wined3d:
            return nil
        case .dxmt where !exportsMacDriverFunctions:
            return "its winemac.so doesn't export macdrv_functions, so DXMT can't present frames (patch it with tools/wine-dxmt/build.sh)"
        case .d3dmetal where !exportsWineUnixCall:
            return "its ntdll.dll lacks __wine_unix_call, so D3DMetal can't load (it needs a CrossOver-based Wine 9 or older)"
        case .d3dmetal where !exportsMacDriverFunctions:
            return "its winemac.so doesn't export macdrv_functions, which D3DMetal presents through"
        default:
            return nil
        }
    }
}

/// Looks up exported symbols in a Mach-O file's export trie.
enum MachOExports {
    static func contains(_ symbol: String, in url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard let trie = exportTrie(buffer) else { return false }
            return lookup(Array(symbol.utf8), in: trie)
        }
    }

    private static func u32(_ b: UnsafeRawBufferPointer, _ o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= b.count else { return nil }
        return b.loadUnaligned(fromByteOffset: o, as: UInt32.self)
    }

    /// The export trie of a 64-bit, little-endian (thin) Mach-O file.
    private static func exportTrie(_ b: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer? {
        guard u32(b, 0) == 0xFEED_FACF, let count = u32(b, 16) else { return nil }
        var command = 32
        for _ in 0..<min(count, 1024) {
            guard let cmd = u32(b, command), let size = u32(b, command + 4), size >= 8 else { return nil }
            var range: (Int, Int)?
            switch cmd {
            case 0x8000_0033:                // LC_DYLD_EXPORTS_TRIE: dataoff, datasize
                if let off = u32(b, command + 8), let len = u32(b, command + 12) { range = (Int(off), Int(len)) }
            case 0x22, 0x8000_0022:          // LC_DYLD_INFO(_ONLY): export_off, export_size
                if let off = u32(b, command + 40), let len = u32(b, command + 44) { range = (Int(off), Int(len)) }
            default:
                break
            }
            if let (off, len) = range, len > 0, off + len <= b.count {
                return UnsafeRawBufferPointer(rebasing: b[off..<(off + len)])
            }
            command += Int(size)
        }
        return nil
    }

    private static func uleb(_ t: UnsafeRawBufferPointer, _ o: inout Int) -> Int? {
        var value = 0, shift = 0
        while o < t.count, shift < 63 {
            let byte = Int(t[o]); o += 1
            value |= (byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func lookup(_ symbol: [UInt8], in t: UnsafeRawBufferPointer) -> Bool {
        var node = 0, matched = 0
        for _ in 0..<4096 {
            var o = node
            guard let terminalSize = uleb(t, &o) else { return false }
            if matched == symbol.count { return terminalSize > 0 }
            o += terminalSize
            guard o < t.count else { return false }
            let children = Int(t[o]); o += 1
            var next: Int?
            for _ in 0..<children {
                var label: [UInt8] = []
                while o < t.count, t[o] != 0 { label.append(t[o]); o += 1 }
                o += 1
                guard let childOffset = uleb(t, &o) else { return false }
                if next == nil, symbol[matched...].starts(with: label) {
                    next = childOffset
                    matched += label.count
                }
            }
            guard let child = next else { return false }
            node = child
        }
        return false
    }
}
