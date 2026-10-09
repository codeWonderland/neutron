import Foundation

public enum NeutronError: Error, CustomStringConvertible, Equatable {
    case invalidName(String)
    case prefixExists(String)
    case prefixNotFound(String)
    case runtimeNotFound(RuntimeKind, version: String?)
    case runtimeExists(RuntimeKind, version: String)
    case invalidRuntime(RuntimeKind, path: String, reason: String)
    case fileNotFound(String)
    case prefixMissingBackendDLLs(prefix: String, runtime: RuntimeKind, files: [String])

    public var description: String {
        switch self {
        case .invalidName(let name):
            return "Invalid name '\(name)'. Use letters, digits, '.', '_' or '-', not starting with '.'."
        case .prefixExists(let name):
            return "Prefix '\(name)' already exists."
        case .prefixNotFound(let name):
            return "Prefix '\(name)' not found. Create it with `neutron prefix create \(name)`."
        case .runtimeNotFound(let kind, let version):
            let which = version.map { "\(kind.rawValue) \($0)" } ?? kind.rawValue
            return "No \(which) runtime registered. Add one with `neutron runtime add \(kind.rawValue) <path>`."
        case .runtimeExists(let kind, let version):
            return "\(kind.rawValue) \(version) is already registered."
        case .invalidRuntime(let kind, let path, let reason):
            return "\(path) is not a valid \(kind.rawValue) runtime: \(reason)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .prefixMissingBackendDLLs(let prefix, let runtime, let files):
            return """
            Prefix '\(prefix)' still lacks \(runtime.rawValue) DLLs after `wineboot -u`: \
            \(files.joined(separator: ", ")). Check the output above, or try a fresh prefix with \
            `neutron prefix create <name>`.
            """
        }
    }
}

func validateName(_ name: String) throws {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    guard !name.isEmpty, !name.hasPrefix("."),
          name.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else { throw NeutronError.invalidName(name) }
}
