import ArgumentParser
import Foundation
import NeutronCore

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check this Mac, the registered runtimes and prefixes for common problems."
    )

    func run() throws {
        let checks = Doctor.checks(host: .current(), runtimes: Env.runtimes, prefixes: Env.prefixes)
        for check in checks {
            let mark: String
            switch check.status {
            case .ok: mark = "ok  "
            case .warning: mark = "warn"
            case .failure: mark = "FAIL"
            }
            print("[\(mark)] \(check.title)")
            if let fix = check.fix, check.status != .ok { print("       \(fix)") }
        }
        if checks.contains(where: { $0.status == .failure }) { throw ExitCode(1) }
    }
}
