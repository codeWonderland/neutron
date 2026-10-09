# CLAUDE.md

Neutron is a Proton-style launcher that runs Windows games on Apple Silicon Macs using Wine,
DXMT and Apple's D3DMetal. Read `PROJECT-OUTLINE.md` for the plan, phase status and decisions.

## Current state: read first

- **The Phase 1 code was written on Linux and has never been compiled.** Before any feature
  work, run `swift build` and `swift test` and fix what breaks. Expect small Swift errors.
- Several layout and loading assumptions are unverified guesses, all listed in
  `docs/phase0-spike.md`. The big one: DXMT and D3DMetal are applied through `WINEDLLPATH` +
  builtin overrides (`Sources/NeutronCore/Backend.swift`). Verify on real hardware with
  `--debug +loaddll` before building on it.
- Phase 0 is hands-on: the user has two Apple Silicon Macs and runs the games. Help them
  gather runtimes, run the checklist and record results in the spike doc's table. Don't
  claim a game works unless it was actually run.

## Commands

```sh
swift build                    # debug build; binary at .build/debug/neutron
swift test                     # unit tests (no Wine needed)
NEUTRON_HOME=/tmp/neutron-dev swift run neutron <args>   # keeps dev state out of ~/Library
swift run neutron run game.exe --dry-run                 # see env + command without launching
```

CI (`.github/workflows/ci.yml`) runs build and test on `macos-15` for every push and PR.

## Layout

- `Sources/NeutronCore/`: all logic, no CLI/UI code (a SwiftUI app will reuse it).
  `Runtime.swift` (runtime registry and layouts), `Prefix.swift`, `Backend.swift` (backend
  env + auto-detection), `PEInfo.swift` (PE import parsing, `GameScan`), `Launcher.swift`
  (`LaunchPlan` building and running).
- `Sources/neutron/`: swift-argument-parser CLI; one file per command group under `Commands/`.
- `Tests/NeutronCoreTests/`: XCTest. Tests use a temp `NeutronPaths` root and fake runtimes.
- `docs/phase0-spike.md`: hardware-spike checklist and results table.

## Conventions

- Keep launch logic pure: build a `LaunchPlan`, test it, and only `Launcher.run` touches
  processes. New behaviour that changes env or args needs a test in `StoreTests` or `BackendTests`.
- Errors that users see go through `NeutronError` with an actionable message (say what to run).
- Don't modify registered runtimes or copy files into prefixes unless Phase 0 shows the
  WINEDLLPATH approach can't work. If it can't, record that in the outline's decision log.
- Game-specific workarounds belong in the Phase 2 compatibility database, not in code.
- **Never commit or bundle Game Porting Toolkit / D3DMetal files.** Users supply their own copy.
- When a phase item lands, tick it in `PROJECT-OUTLINE.md`. Add a decision-log row for
  any design change.
