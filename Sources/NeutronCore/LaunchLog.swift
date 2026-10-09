import Foundation

/// Per-launch log files: `logs/<prefix>/<yyyyMMdd-HHmmss>-<program>.log` under the state root.
///
/// Wine's output goes straight to the file (both streams, in order) and Neutron echoes the
/// file to the terminal while the game runs. A pipe would be simpler, but Wine's background
/// processes (wineserver, services) inherit it and outlive the game.
public enum LaunchLog {
    /// How many logs to keep per prefix.
    public static let retained = 20

    public static func url(paths: NeutronPaths, prefix: String, program: URL, date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let stem = program.deletingPathExtension().lastPathComponent.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }.joined()
        return paths.logs.appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent("\(formatter.string(from: date))-\(stem).log")
    }

    /// What was run, so a log can be shared on its own.
    public static func header(for plan: LaunchPlan, date: Date) -> String {
        var lines = ["# Neutron launch, \(ISO8601DateFormatter().string(from: date))"]
        if let backend = plan.backend { lines.append("# backend: \(backend.rawValue)") }
        if let composition = plan.composition { lines.append("# composed runtime: \(composition.path.path)") }
        lines += plan.notes.map { "# note: \($0)" }
        lines += plan.environment.sorted { $0.key < $1.key }.map { "# env \($0.key)=\($0.value)" }
        if let directory = plan.workingDirectory { lines.append("# cd \(directory.path)") }
        lines.append("# " + ([plan.executable.path] + plan.arguments).joined(separator: " "))
        return lines.joined(separator: "\n") + "\n\n"
    }

    /// Deletes all but the newest `keep` logs in `directory` (names sort by date).
    public static func prune(directory: URL, keep: Int = retained) {
        let fm = FileManager.default
        let logs = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".log") }
            .sorted()
        for name in logs.dropLast(keep) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
