# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Neutron is a Proton-style launcher that runs Windows games on Apple Silicon Macs using Wine,
DXMT and Apple's D3DMetal. Read `PROJECT-OUTLINE.md` for the plan, phase status and decisions.

## Current state: read first

- Phase 0 is under way (`docs/phase0-spike.md` has findings and results). The WINEDLLPATH
  design **failed** and was replaced by composed runtimes. DXMT can only present frames on
  a Wine whose `winemac.so` exports `macdrv_functions`: use `tools/wine-dxmt/build.sh` on a
  Gcenx build (verified with 11.18), or a CrossOver-based build (Wine 9-based: no Unity 6
  mouse input). The README's "What you need" lists where every dependency comes from.
- Engine-aware detection (Unity, Unreal, Godot) is built and checked against a real
  105-game library and 10+ launched games (`docs/phase0-spike.md`).
- D3DMetal is verified on a CrossOver-based Wine 9 (Sikarugir CX 24) but can't run on Wine
  10+; `WineCapabilities.swift` reads each Wine build's exports and the launcher falls back
  to DXMT. Unity games never get D3D12 from D3DMetal (no D3D11On12), so they go to DXMT.
- **Still unverified:** D3D9 and 32-bit games; Steam-integrated games need the Steam client
  (Phase 3). Don't build on those assumptions until tested.
- Phase 0 is hands-on: the user has two Apple Silicon Macs and runs the games. Help them
  gather runtimes, run the checklist and record results in the spike doc's table. Don't
  claim a game works unless it was actually run.

## Commands

```sh
swift build                    # debug build; binary at .build/debug/neutron
swift test                     # unit tests (no Wine needed)
swift test --filter BackendTests                      # one test class
swift test --filter BackendTests/testDXMTSetup        # one test
NEUTRON_HOME=/tmp/neutron-dev swift run neutron <args>   # keeps dev state out of ~/Library
swift run neutron run game.exe --dry-run                 # see env + command without launching
```

Requires macOS 14+ on Apple Silicon and Xcode 16 / Swift 6 toolchain (package is
swift-tools 5.9). CI (`.github/workflows/ci.yml`) runs build and test on `macos-15` for
every push and PR. There is no linter configured.

## How a launch is built

`Launcher.gamePlan` (`Launcher.swift`) is the core path:

1. **Backend choice**, first match wins: `--backend` flag → backend pinned in the prefix's
   config → `GameScan` auto-detect. `Engine.swift` recognises Unity, Unreal (following
   Unreal stub exes to `*-Shipping.exe`) and Godot. Unity → `dxmt`; Unreal with a shipped
   D3D12 Agility SDK → `d3dmetal` (falls back to `dxmt`), else `dxmt`; Godot → no Direct3D
   layer (Godot 4 gets `--rendering-driver vulkan`). Other games
   use PE imports of the exe and sibling DLLs (minus middleware like EOS/CEF): d3d12 →
   `d3dmetal`, d3d10/11/dxgi → `dxmt`, else `wined3d`. On backends without D3D12, engine
   Unreal stubs are replaced by their Shipping exe at launch (`--launch-stub` to opt out).
   Unreal games get `-dx11` unless `--no-engine-args`; Unity gets no flag (it falls back to
   D3D11 itself, and forcing breaks builds without D3D11 shaders).
2. **Runtimes**: each backend's `requiredRuntime` (dxmt → `dxmt`, d3dmetal → `gptk`) and Wine
   (version pinned by the prefix, else newest) come from `RuntimeStore`, a JSON manifest that
   records paths to user-downloaded runtimes; nothing is copied. `Runtime` computes per-kind
   layout paths (`wineBinary`, `wineDLLDirectory`, `externalLibraryDirectory`).
   `resolveRoot` also looks one folder down, since release archives extract into a wrapper
   folder. Wine and DXMT layouts are verified; GPTK's is still a guess.
3. **Backend**: `BackendSetup.make` yields builtin DLL overrides and an `overlay` runtime.
   With an overlay, the plan's executable is inside a `ComposedRuntime` (APFS clone of Wine
   with the backend copied into `lib/wine/<arch>`, cached in `runtimes/composed/`).
   `Launcher.run` builds it on demand and runs `wineboot -u` if the prefix lacks any of the
   backend's DLLs; Wine only loads a builtin that has a copy in `system32`/`syswow64`.
   Before that, `WineCapabilities` (exports of the Wine build's `winemac.so`/`ntdll.dll`)
   can swap an auto-picked backend for its fallback, or add a warning note.
4. **Env**: `winePlan` merges in this order: Neutron defaults (`WINEPREFIX`,
   `WINEDEBUG=-all`, `WINEMSYNC=1`, `MVK_CONFIG_LOG_LEVEL=1`, plus
   `DYLD_FALLBACK_LIBRARY_PATH` from the Wine runtime's `libraryPaths`) → backend env → prefix
   `environment` overrides everything, except `WINEDLLOVERRIDES`, which is appended after
   the backend's.

State lives under `NeutronPaths` (`~/Library/Application Support/Neutron`, or `NEUTRON_HOME`):
`prefixes/<name>/neutron.json` (config) + `prefixes/<name>/pfx/` (the actual `WINEPREFIX`),
`runtimes/manifest.json`, disposable `runtimes/composed/<wine>+<kind>-<version>/` builds, and
`logs/<prefix>/` (per-launch logs; `LaunchLog.swift` explains why it's a file, not a pipe).

## Layout

- `Sources/NeutronCore/`: all logic, no CLI/UI code (a SwiftUI app will reuse it).
  `Runtime.swift` (runtime registry and layouts), `Prefix.swift`, `Backend.swift` (backend
  setup + `BackendResolver`), `Engine.swift` (Unity/Unreal detection, engine flags),
  `ComposedRuntime.swift` (clone + overlay), `PEInfo.swift` (PE import parsing, `GameScan`),
  `WineCapabilities.swift` (what a Wine build supports, Mach-O/PE export reading),
  `Doctor.swift` (`neutron doctor` checks), `LaunchLog.swift`, `Launcher.swift`
  (`LaunchPlan` building and running).
- `Sources/neutron/`: swift-argument-parser CLI; one file per command group under `Commands/`.
- `Tests/NeutronCoreTests/`: XCTest. Tests use a temp `NeutronPaths` root and fake runtimes;
  `Fixtures.makePE(imports:)` builds minimal PE files for detection tests.
- `docs/phase0-spike.md`: hardware-spike checklist, findings and results tables.
- `tools/smoke/`: `smoke.sh <prefix> <exe> [seconds]` launches through Neutron, captures the
  game's own window (`winshot.swift`, needs Screen Recording permission), stops the prefix,
  and prints PASS when the window isn't black. Use it to check games instead of guessing.
- `tools/wine-dxmt/`: Wine patch + script that makes a DXMT-capable copy of a macOS Wine
  build by rebuilding only `winemac.so` (needs `brew install bison flex mingw-w64`).
- `tools/d3dprobe/`: tiny D3D9/D3D11/D3D12 Windows program for checking a backend without a game
  (`tools/d3dprobe/build.sh`, needs `brew install mingw-w64`). wined3d answers as a fake
  "NVIDIA GeForce 6800" at FL 9.3; DXMT answers as the real Apple GPU. It only creates a
  device, so it can't catch presentation problems; check those with a windowed game.

## Conventions

- Keep launch logic pure: build a `LaunchPlan`, test it, and only `Launcher.run` touches
  processes or composes runtimes. New behaviour that changes env or args needs a test in `StoreTests` or `BackendTests`.
- Errors that users see go through `NeutronError` with an actionable message (say what to run).
- Never modify registered runtimes; backend files go into composed clones only. Get DLLs
  into prefixes through `wineboot -u`, not by copying them in yourself.
- Upstream Wine ignores `WINEDLLPATH` for DLLs it ships; don't use it to apply backends.
- When testing Wine by hand, don't wrap it in `/usr/bin/perl` or other system binaries:
  macOS strips `DYLD_*` variables when launching SIP-protected programs.
- Game-specific workarounds belong in the Phase 2 compatibility database, not in code.
- **Never commit or bundle Game Porting Toolkit / D3DMetal files.** Users supply their own copy.
- When a phase item lands, tick it in `PROJECT-OUTLINE.md`. Add a decision-log row for
  any design change.
