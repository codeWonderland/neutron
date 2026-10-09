import Foundation

public enum PEError: Error, CustomStringConvertible, Equatable {
    case notPE(String)
    case truncated

    public var description: String {
        switch self {
        case .notPE(let reason): return "Not a Windows executable: \(reason)"
        case .truncated: return "Executable is truncated or malformed"
        }
    }
}

/// The parts of a Windows PE file Neutron cares about: architecture and imported DLLs.
public struct PEInfo: Equatable, Sendable {
    public enum Machine: Equatable, Sendable {
        case i386, x86_64, arm64, other(UInt16)

        init(_ raw: UInt16) {
            switch raw {
            case 0x014C: self = .i386
            case 0x8664: self = .x86_64
            case 0xAA64: self = .arm64
            default: self = .other(raw)
            }
        }
    }

    public let machine: Machine
    /// Lowercased DLL names from the import and delay-import tables.
    public let imports: Set<String>
    /// Names in the export table, as written (case-sensitive).
    public let exports: Set<String>

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        let r = ByteReader(data: data)
        guard try r.u16(0) == 0x5A4D else { throw PEError.notPE("missing MZ header") }
        let pe = Int(try r.u32(0x3C))
        guard try r.u32(pe) == 0x0000_4550 else { throw PEError.notPE("missing PE signature") }

        let coff = pe + 4
        machine = Machine(try r.u16(coff))
        let sectionCount = Int(try r.u16(coff + 2))
        let optionalSize = Int(try r.u16(coff + 16))
        let opt = coff + 20

        let magic = try r.u16(opt)
        let is64: Bool
        switch magic {
        case 0x10B: is64 = false
        case 0x20B: is64 = true
        default: throw PEError.notPE("unknown optional header magic \(magic)")
        }
        let imageBase = try is64 ? r.u64(opt + 24) : UInt64(r.u32(opt + 28))
        let directoryCount = Int(try r.u32(opt + (is64 ? 108 : 92)))
        let directories = opt + (is64 ? 112 : 96)

        var sections: [(va: UInt32, size: UInt32, raw: UInt32)] = []
        let sectionTable = opt + optionalSize
        for i in 0..<sectionCount {
            let s = sectionTable + i * 40
            let virtualSize = try r.u32(s + 8)
            let rawSize = try r.u32(s + 16)
            let va = try r.u32(s + 12)
            let raw = try r.u32(s + 20)
            sections.append((va: va, size: max(virtualSize, rawSize), raw: raw))
        }
        func offset(ofRVA rva: UInt32) -> Int? {
            for s in sections where rva >= s.va && rva - s.va < s.size {
                return Int(s.raw) + Int(rva - s.va)
            }
            return nil
        }

        var names = Set<String>()
        let maxEntries = 4096

        // Import directory (index 1): 20-byte descriptors, name RVA at +12.
        if directoryCount > 1, let table = offset(ofRVA: try r.u32(directories + 8)) {
            for i in 0..<maxEntries {
                let d = table + i * 20
                let nameRVA = try r.u32(d + 12)
                let firstThunk = try r.u32(d + 16)
                if nameRVA == 0 && firstThunk == 0 { break }
                if let o = offset(ofRVA: nameRVA), let name = r.cString(o) { names.insert(name.lowercased()) }
            }
        }

        // Delay-import directory (index 13): 32-byte descriptors, attributes at +0, name at +4.
        if directoryCount > 13, let table = offset(ofRVA: try r.u32(directories + 13 * 8)) {
            for i in 0..<maxEntries {
                let d = table + i * 32
                let attributes = try r.u32(d)
                var name = UInt64(try r.u32(d + 4))
                if name == 0 { break }
                // Old-style descriptors (attribute bit 0 clear) hold VAs instead of RVAs.
                if attributes & 1 == 0 {
                    guard name >= imageBase else { continue }
                    name -= imageBase
                }
                if name <= UInt64(UInt32.max), let o = offset(ofRVA: UInt32(name)), let dll = r.cString(o) {
                    names.insert(dll.lowercased())
                }
            }
        }
        imports = names

        // Export directory (index 0): name count at +24, name-pointer table RVA at +32.
        var exported = Set<String>()
        if directoryCount > 0, let table = offset(ofRVA: try r.u32(directories)) {
            let count = min(Int(try r.u32(table + 24)), 65536)
            if count > 0, let pointers = offset(ofRVA: try r.u32(table + 32)) {
                for i in 0..<count {
                    if let o = offset(ofRVA: try r.u32(pointers + i * 4)), let name = r.cString(o) { exported.insert(name) }
                }
            }
        }
        exports = exported
    }
}

private struct ByteReader {
    let data: Data

    private func byte(_ offset: Int) throws -> UInt64 {
        guard offset >= 0, offset < data.count else { throw PEError.truncated }
        return UInt64(data[data.startIndex + offset])
    }

    private func read(_ offset: Int, _ width: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<width { value |= try byte(offset + i) << (8 * UInt64(i)) }
        return value
    }

    func u16(_ offset: Int) throws -> UInt16 { UInt16(try read(offset, 2)) }
    func u32(_ offset: Int) throws -> UInt32 { UInt32(try read(offset, 4)) }
    func u64(_ offset: Int) throws -> UInt64 { try read(offset, 8) }

    func cString(_ offset: Int, maxLength: Int = 256) -> String? {
        var bytes: [UInt8] = []
        for i in 0..<maxLength {
            guard let b = try? byte(offset + i) else { return nil }
            if b == 0 { break }
            bytes.append(UInt8(b))
        }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }
}

public struct GameScan: Sendable {
    /// The executable that will be launched.
    public let executable: PEInfo
    /// Engine details, when the game uses Unity or Unreal.
    public let engine: EngineDetection?
    /// Imports of the renderer binary (the exe, or the Unreal Shipping exe a stub starts)
    /// plus every DLL next to it, since engines like Unity keep their renderer in a sibling
    /// DLL (UnityPlayer.dll) rather than the exe.
    public let imports: Set<String>
    public let recommendation: BackendRecommendation

    public init(executable url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw NeutronError.fileNotFound(url.path) }
        executable = try PEInfo(contentsOf: url)
        engine = EngineDetection.detect(executable: url)
        let renderer = engine?.renderer ?? url
        var all = renderer == url ? executable.imports : ((try? PEInfo(contentsOf: renderer))?.imports ?? [])
        let directory = renderer.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for dll in siblings where dll.pathExtension.lowercased() == "dll" && !GameScan.isMiddleware(dll) {
            if let info = try? PEInfo(contentsOf: dll) { all.formUnion(info.imports) }
        }
        imports = all
        recommendation = BackendResolver.recommend(imports: all, engine: engine)
    }

    /// Middleware that imports graphics APIs for its own overlay or embedded browser, not
    /// for the game's renderer (Epic Online Services and CEF import d3d12 even in D3D11 games).
    static func isMiddleware(_ dll: URL) -> Bool {
        let name = dll.lastPathComponent.lowercased()
        return ["eossdk-", "libcef", "steam_api", "discord_", "gameoverlayrenderer", "galaxy"]
            .contains { name.hasPrefix($0) }
    }
}
