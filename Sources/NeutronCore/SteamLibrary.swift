import Foundation

/// Valve's KeyValues text format (VDF/ACF): `"key" "value"` pairs and `"key" { ... }` blocks.
public indirect enum VDF: Equatable, Sendable {
    case value(String)
    case object([(String, VDF)])

    public static func == (lhs: VDF, rhs: VDF) -> Bool {
        switch (lhs, rhs) {
        case (.value(let a), .value(let b)): return a == b
        case (.object(let a), .object(let b)): return a.map(\.0) == b.map(\.0) && zip(a, b).allSatisfy { $0.1 == $1.1 }
        default: return false
        }
    }

    /// The first child with this key (case-insensitive, as Steam treats them).
    public subscript(key: String) -> VDF? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
    }

    public var string: String? {
        if case .value(let s) = self { return s }
        return nil
    }

    public var children: [(String, VDF)] {
        if case .object(let pairs) = self { return pairs }
        return []
    }

    /// Parses a document: a sequence of top-level pairs, returned as one object.
    public static func parse(_ text: String) throws -> VDF {
        var scanner = Scanner(Array(text.unicodeScalars))
        let pairs = try scanner.pairs(untilBrace: false)
        return .object(pairs)
    }

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    private struct Scanner {
        let chars: [Unicode.Scalar]
        var i = 0
        init(_ chars: [Unicode.Scalar]) { self.chars = chars }

        mutating func skipSpaceAndComments() {
            while i < chars.count {
                if chars[i].properties.isWhitespace { i += 1; continue }
                if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    continue
                }
                break
            }
        }

        mutating func token() throws -> String? {
            skipSpaceAndComments()
            guard i < chars.count else { return nil }
            var out = String.UnicodeScalarView()
            if chars[i] == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count {
                        i += 1
                        switch chars[i] {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        default: out.append(chars[i])
                        }
                    } else {
                        out.append(chars[i])
                    }
                    i += 1
                }
                guard i < chars.count else { throw ParseError(description: "unterminated string") }
                i += 1
                return String(out)
            }
            while i < chars.count, !chars[i].properties.isWhitespace, chars[i] != "{", chars[i] != "}", chars[i] != "\"" {
                out.append(chars[i]); i += 1
            }
            return String(out)
        }

        mutating func pairs(untilBrace: Bool) throws -> [(String, VDF)] {
            var result: [(String, VDF)] = []
            while true {
                skipSpaceAndComments()
                guard i < chars.count else {
                    if untilBrace { throw ParseError(description: "missing }") }
                    return result
                }
                if chars[i] == "}" {
                    guard untilBrace else { throw ParseError(description: "unexpected }") }
                    i += 1
                    return result
                }
                guard let key = try token() else { return result }
                skipSpaceAndComments()
                guard i < chars.count else { throw ParseError(description: "missing value for \(key)") }
                if chars[i] == "{" {
                    i += 1
                    result.append((key, .object(try pairs(untilBrace: true))))
                } else if let value = try token() {
                    result.append((key, .value(value)))
                }
                // Conditionals like [$WIN32] after a value are skipped.
                skipSpaceAndComments()
                if i < chars.count, chars[i] == "[" { while i < chars.count, chars[i] != "]" { i += 1 }; i += 1 }
            }
        }
    }
}

/// A game Steam has installed, from `steamapps/appmanifest_<appid>.acf`.
public struct SteamGame: Equatable, Sendable {
    public let appID: String
    public let name: String
    /// `steamapps/common/<installdir>`.
    public let directory: URL
    /// StateFlags bit 4 (fully installed); it stays set while an update is pending (bit 2).
    public let fullyInstalled: Bool
}

public enum SteamLibrary {
    /// Library folders (each holding `steamapps/`): Steam's own folder plus those listed in
    /// `steamapps/libraryfolders.vdf`. Windows paths are mapped into the prefix's drive_c.
    public static func folders(steamRoot: URL, winePrefix: URL) -> [URL] {
        var result = [steamRoot]
        let file = steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: file, encoding: .utf8), let vdf = try? VDF.parse(text),
           let list = vdf["libraryfolders"] {
            for (_, entry) in list.children {
                // Old format: "1" "D:\\Games"; new format: "0" { "path" "..." }
                guard let path = entry["path"]?.string ?? entry.string,
                      let url = hostURL(windowsPath: path, winePrefix: winePrefix) else { continue }
                if !result.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
                    result.append(url)
                }
            }
        }
        return result
    }

    /// Maps `C:\...` (drive_c) and `Z:\...` (the Mac's root) to host paths.
    public static func hostURL(windowsPath: String, winePrefix: URL) -> URL? {
        let path = windowsPath.replacingOccurrences(of: "\\", with: "/")
        guard path.count >= 2, path.dropFirst().first == ":" else { return nil }
        let drive = path.prefix(1).lowercased()
        let rest = String(path.dropFirst(2))
        switch drive {
        case "c": return winePrefix.appendingPathComponent("drive_c").appendingPathComponent(rest)
        case "z": return URL(fileURLWithPath: rest.isEmpty ? "/" : rest)
        default:
            // Other drives are symlinks in dosdevices.
            let link = winePrefix.appendingPathComponent("dosdevices/\(drive):")
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
            let base = target.hasPrefix("/") ? URL(fileURLWithPath: target) : link.deletingLastPathComponent().appendingPathComponent(target)
            return base.appendingPathComponent(rest)
        }
    }

    /// Installed games across all library folders, sorted by name.
    public static func games(steamRoot: URL, winePrefix: URL) -> [SteamGame] {
        var games: [SteamGame] = []
        for folder in folders(steamRoot: steamRoot, winePrefix: winePrefix) {
            let steamapps = folder.appendingPathComponent("steamapps")
            let files = (try? FileManager.default.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
                guard let text = try? String(contentsOf: file, encoding: .utf8), let vdf = try? VDF.parse(text),
                      let state = vdf["AppState"], let appID = state["appid"]?.string,
                      let installdir = state["installdir"]?.string else { continue }
                let flags = Int(state["StateFlags"]?.string ?? "") ?? 0
                games.append(SteamGame(appID: appID, name: state["name"]?.string ?? installdir,
                                       directory: steamapps.appendingPathComponent("common").appendingPathComponent(installdir),
                                       fullyInstalled: flags & 4 != 0))
            }
        }
        return games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension SteamLibrary {
    /// Adds an existing copy of a game (e.g. from another machine's Steam library) to Steam's own
    /// library so it doesn't have to be downloaded again: the folder is cloned (free on APFS) to
    /// `steamapps/common/<folder name>` and an `appmanifest_<appid>.acf` marks it as needing an
    /// update, so the next time Steam starts it verifies the files and fetches only what differs.
    @discardableResult
    public static func importGame(from source: URL, appID: String, name: String? = nil, steamRoot: URL) throws -> URL {
        guard !appID.isEmpty, appID.allSatisfy(\.isNumber) else { throw NeutronError.invalidName(appID) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw NeutronError.fileNotFound(source.path) }
        let steamapps = steamRoot.appendingPathComponent("steamapps")
        let installdir = source.standardizedFileURL.lastPathComponent
        let destination = steamapps.appendingPathComponent("common").appendingPathComponent(installdir)
        let manifest = steamapps.appendingPathComponent("appmanifest_\(appID).acf")
        guard !fm.fileExists(atPath: destination.path), !fm.fileExists(atPath: manifest.path) else {
            throw NeutronError.steamGameExists(appID: appID, path: destination.path)
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)  // clonefile on APFS
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let text = """
        "AppState"
        {
        \t"appid"\t\t\(quoted(appID))
        \t"Universe"\t\t"1"
        \t"name"\t\t\(quoted(name ?? installdir))
        \t"StateFlags"\t\t"1026"
        \t"installdir"\t\t\(quoted(installdir))
        \t"LastUpdated"\t\t"0"
        \t"SizeOnDisk"\t\t"0"
        \t"buildid"\t\t"0"
        \t"BytesToDownload"\t\t"0"
        \t"BytesDownloaded"\t\t"0"
        \t"AutoUpdateBehavior"\t\t"0"
        \t"UserConfig"
        \t{
        \t}
        \t"MountedDepots"
        \t{
        \t}
        }

        """
        try Data(text.utf8).write(to: manifest)
        return destination
    }
}
