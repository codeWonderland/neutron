import Foundation

/// `neutron doctor`: checks the machine, registered runtimes and prefixes for the problems
/// Phase 0 ran into, and says how to fix each one.
public enum Doctor {
    public struct Check: Equatable, Sendable {
        public enum Status: Equatable, Sendable { case ok, warning, failure }
        public let status: Status
        public let title: String
        /// How to fix it, for warnings and failures.
        public let fix: String?

        public init(_ status: Status, _ title: String, fix: String? = nil) {
            self.status = status
            self.title = title
            self.fix = fix
        }
    }

    /// Facts about the host, injected so the checks can be tested.
    public struct Host: Sendable {
        public var macOSVersion: OperatingSystemVersion
        public var isAppleSilicon: Bool
        public var rosettaInstalled: Bool

        public init(macOSVersion: OperatingSystemVersion, isAppleSilicon: Bool, rosettaInstalled: Bool) {
            self.macOSVersion = macOSVersion
            self.isAppleSilicon = isAppleSilicon
            self.rosettaInstalled = rosettaInstalled
        }

        public static func current() -> Host {
            var arm64: Int32 = 0
            var size = MemoryLayout<Int32>.size
            sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0)
            return Host(macOSVersion: ProcessInfo.processInfo.operatingSystemVersion,
                        isAppleSilicon: arm64 == 1,
                        rosettaInstalled: FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime"))
        }
    }

    public static func checks(host: Host, runtimes: RuntimeStore, prefixes: PrefixStore,
                              capabilities: (Runtime) -> WineCapabilities = { WineCapabilities(wine: $0) }) -> [Check] {
        var checks: [Check] = []
        let v = host.macOSVersion
        let version = "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        if v.majorVersion < 14 {
            checks.append(Check(.failure, "macOS \(version)", fix: "Neutron needs macOS 14 or later."))
        } else {
            checks.append(Check(.ok, "macOS \(version)"))
        }
        checks.append(host.isAppleSilicon
            ? Check(.ok, "Apple Silicon")
            : Check(.failure, "Not an Apple Silicon Mac", fix: "DXMT and D3DMetal need Apple Silicon."))
        checks.append(host.rosettaInstalled
            ? Check(.ok, "Rosetta 2 installed")
            : Check(.failure, "Rosetta 2 not installed", fix: "Run `softwareupdate --install-rosetta`."))

        let all = (try? runtimes.list()) ?? []
        let fm = FileManager.default
        for kind in RuntimeKind.allCases where !all.contains(where: { $0.kind == kind }) {
            switch kind {
            case .wine:
                checks.append(Check(.failure, "No Wine registered", fix: "See README \"What you need\", then `neutron runtime add wine <path>`."))
            case .dxmt:
                checks.append(Check(.warning, "No DXMT registered (D3D10/11 games fall back to wined3d)",
                                    fix: "Download a dxmt-*-builtin release, then `neutron runtime add dxmt <path>`."))
            case .gptk:
                checks.append(Check(.ok, "No Game Porting Toolkit registered (optional; D3D12 games use DXMT where they can)"))
            }
        }

        var dxmtCapableWine = false
        for runtime in all.sorted(by: { ($0.kind.rawValue, $0.version) < ($1.kind.rawValue, $1.version) }) {
            let name = "\(runtime.kind.rawValue) \(runtime.version)"
            guard (try? Runtime.resolveRoot(kind: runtime.kind, at: runtime.path)) != nil else {
                checks.append(Check(.failure, "\(name): missing or broken at \(runtime.path.path)",
                                    fix: "Re-download it, or `neutron runtime remove \(runtime.kind.rawValue) \(runtime.version)`."))
                continue
            }
            for library in runtime.libraryPaths ?? [] where !fm.fileExists(atPath: library.path) {
                checks.append(Check(.failure, "\(name): library path \(library.path) is missing",
                                    fix: "Restore it, or re-add the runtime with the right --library-path."))
            }
            guard runtime.kind == .wine else {
                checks.append(Check(.ok, runtime.kind == .dxmt
                    ? "\(name) (cross-process for Steam's UI: \(runtime.dxmtPresentsCrossProcess ? "yes" : "no"))" : name))
                continue
            }
            // Wrapper-app engines (Sikarugir) expect their host app's dylibs.
            let searched = [runtime.path.appendingPathComponent("lib"), runtime.path.appendingPathComponent("lib/wine/x86_64-unix"),
                            runtime.path.appendingPathComponent("bin")] + (runtime.libraryPaths ?? [])
            let missing = MachOExports.rpathDylibs(in: runtime.path.appendingPathComponent("bin/wineserver"))
                .filter { name in !searched.contains { fm.fileExists(atPath: $0.appendingPathComponent(name).path) } }
            if !missing.isEmpty {
                checks.append(Check(.failure, "\(name): needs libraries it doesn't ship (\(missing.joined(separator: ", ")))",
                                    fix: "Re-add it with --library-path pointing at its wrapper's Frameworks folder (e.g. a Sikarugir Template.app/Contents/Frameworks)."))
            }
            // winegstreamer plays Media Foundation video (intros, cutscenes); without GStreamer
            // those games hang on a black screen or skip the video.
            let gstreamerLinked = MachOExports.rpathDylibs(in: runtime.path.appendingPathComponent("lib/wine/x86_64-unix/winegstreamer.so"))
                .contains("libgstreamer-1.0.0.dylib")
            if let gstreamer = runtime.gstreamer {
                if (try? Runtime.resolveGStreamer(at: gstreamer)) == nil {
                    checks.append(Check(.failure, "\(name): GStreamer at \(gstreamer.path) is missing",
                                        fix: "Reinstall it, or run `neutron runtime set-gstreamer \(runtime.version) <path>` (or `none`)."))
                }
            } else if gstreamerLinked {
                checks.append(Check(.warning, "\(name): no GStreamer, so in-game videos won't play",
                                    fix: "Install the GStreamer runtime package (README \"What you need\"), then `neutron runtime set-gstreamer \(runtime.version) /Library/Frameworks/GStreamer.framework`."))
            }
            let caps = capabilities(runtime)
            dxmtCapableWine = dxmtCapableWine || caps.supports(.dxmt)
            let wow64 = fm.isExecutableFile(atPath: runtime.path.appendingPathComponent("bin/wine").path)
            func mark(_ yes: Bool) -> String { yes ? "yes" : "no" }
            let summary = "\(name): DXMT \(mark(caps.supports(.dxmt))), D3DMetal \(mark(caps.supports(.d3dmetal))), "
                + "msync \(mark(caps.hasMsync)), \(wow64 ? "wow64" : "no wow64 (32-bit games may fail)")"
                + ", cross-process (Steam UI) \(mark(caps.presentsCrossProcess))"
            checks.append(Check(caps.supports(.dxmt) ? .ok : .warning, summary,
                                fix: caps.problem(with: .dxmt).map { "For DXMT: \($0)." }))
        }
        if all.contains(where: { $0.kind == .dxmt }), all.contains(where: { $0.kind == .wine }), !dxmtCapableWine {
            checks.append(Check(.warning, "No registered Wine can present DXMT frames; D3D11 games will start but show nothing",
                                fix: "Make one with `tools/wine-dxmt/build.sh` and register it."))
        }

        for prefix in (try? prefixes.list()) ?? [] {
            let name = "prefix \(prefix.config.name)"
            if let pinned = prefix.config.wineVersion, !all.contains(where: { $0.kind == .wine && $0.version == pinned }) {
                checks.append(Check(.failure, "\(name): pinned Wine \(pinned) isn't registered",
                                    fix: "Register it, or edit \(prefix.directory.appendingPathComponent("neutron.json").path)."))
            } else if let (kind, pinned) = (prefix.config.runtimeVersions ?? [:]).sorted(by: { $0.key < $1.key })
                        .first(where: { pin in !all.contains { $0.kind.rawValue == pin.key && $0.version == pin.value } }) {
                checks.append(Check(.failure, "\(name): pinned \(kind) \(pinned) isn't registered",
                                    fix: "Register it, or `neutron prefix set-runtime \(prefix.config.name) \(kind) newest`."))
            } else if !fm.fileExists(atPath: prefix.winePrefix.appendingPathComponent("system.reg").path) {
                checks.append(Check(.warning, "\(name): not initialized",
                                    fix: "Run `neutron wine -p \(prefix.config.name) -- wineboot --init`."))
            } else {
                checks.append(Check(.ok, name))
            }
        }
        return checks
    }
}
