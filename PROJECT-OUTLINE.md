# Project Outline

The living plan for Neutron. Update the status boxes and the decision log as work lands.

## Vision

Proton made Windows gaming on Linux mostly "click Play". Proton's value isn't one new
translation layer. It's the **curation and integration** of Wine, DXVK and VKD3D-Proton, plus
a per-game fix database. Neutron does the same for Apple Silicon Macs, using Wine, DXMT,
D3DMetal and Rosetta 2.

Non-goals: writing our own graphics translation layer, patching Wine internals in this repo,
bundling Apple's D3DMetal, and supporting kernel anti-cheat.

## Architecture

```
neutron (CLI, Sources/neutron)          future: Neutron.app (SwiftUI)
        │                                       │
        └──────────────► NeutronCore ◄──────────┘
                           │
   RuntimeStore ── registered Wine / DXMT / GPTK builds (runtimes/manifest.json)
   PrefixStore  ── prefixes/<name>/{neutron.json, pfx/}
   PEInfo/GameScan ── reads PE import tables → BackendResolver picks a backend
   BackendSetup ── WINEDLLPATH + WINEDLLOVERRIDES (+ DYLD paths for D3DMetal)
   Launcher     ── builds a LaunchPlan (pure, testable), then runs it with Process
```

State root: `~/Library/Application Support/Neutron` (override with `NEUTRON_HOME`).

**Core design bet:** backends are applied per launch through `WINEDLLPATH` and builtin
overrides. Nothing is copied into prefixes or Wine builds. This is **unverified**. Phase 0
tests it, and the fallback is a "composed runtime" (an APFS clone of Wine with the
backend's files overlaid), which only changes `BackendSetup`.

## Phases

### Phase 0: Spike (hands-on, real hardware)
Checklist: [docs/phase0-spike.md](docs/phase0-spike.md)
- [ ] First `swift build` / `swift test` on macOS (the code was written on Linux and never compiled)
- [ ] Gather Wine (wow64 + msync), DXMT and GPTK; record their exact folder layouts
- [ ] Verify the WINEDLLPATH approach for DXMT and D3DMetal, or switch to composed runtimes
- [ ] Run one D3D9, D3D11, D3D12 and 32-bit game; fill in the results table
- [ ] Check whether Unreal stub exes need detection to follow `Binaries/Win64/*-Shipping.exe`

### Phase 1: CLI runtime and prefix manager *(scaffolded)*
- [x] `runtime add/list/remove`: register on-disk runtimes
- [x] `prefix create/list/delete/set-backend/set-env`
- [x] `detect`: PE import scan of exe and sibling DLLs → backend recommendation
- [x] `run`: launch with auto/explicit backend, `--hud`, `--debug`, `--dry-run`
- [x] `wine`: raw Wine commands in a prefix
- [ ] Fix whatever Phase 0 finds (layouts, load paths)
- [ ] Log files per launch (`logs/<prefix>/<timestamp>.log`) with tee to the terminal
- [ ] `neutron doctor`: check for Rosetta, runtimes, macOS version and common problems
- [ ] DXVK + MoltenVK as a fourth backend (for D3D11 games DXMT can't handle)

### Phase 2: Compatibility database
- [ ] Schema: `games/<steam-appid or exe-hash>.toml` with backend, env, DLL overrides,
      winetricks verbs, launch args, status (platinum/gold/…), notes, tested Wine/macOS versions
- [ ] Match games by Steam app ID, then by exe name + hash
- [ ] Apply entries automatically in `run`, with `--no-db` to bypass
- [ ] `neutron report`: produce a result entry (env, versions, outcome) for a PR
- [ ] Seed with Phase 0 results

### Phase 3: Steam integration
- [ ] `neutron steam install`: Windows Steam in a shared prefix
- [ ] Find installed games through `steamapps/appmanifest_*.acf`; launch by app ID
- [ ] Stretch: read the native macOS Steam library and offer the Windows build of non-Mac games

### Phase 4: SwiftUI app
- [ ] Library grid (Steam + manual games), per-game settings, backend picker
- [ ] HUD toggle, live log view, "report result" flow
- [ ] Runtime manager UI

### Phase 5: Hardening and distribution
- [ ] Managed runtime downloads (Wine, DXMT) with checksums; GPTK import assistant
- [ ] Code signing, notarization, Homebrew cask
- [ ] Crash/diagnostic bundle (`neutron bug-report`)
- [ ] Automated smoke tests on free games (launch, screenshot, check for a non-black frame)

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Rosetta 2 phased out after macOS 27 (subset kept for older games) | Could break x86 games | Follow Apple's announcements; watch FEX/Box64-style ARM translators for Wine |
| WINEDLLPATH approach doesn't work | Phase 1 rework | Composed-runtime fallback, isolated to `BackendSetup` |
| GPTK licence | Can't bundle D3DMetal | Users import their own copy |
| Competing with CrossOver, which funds most Wine-on-Mac work | Community friction (Whisky was archived partly for this) | Upstream fixes; credit and link CodeWeavers; stay a thin layer |
| Kernel anti-cheat | Some games never work | Mark them clearly in the database |

## Decision log

| Date | Decision | Why |
|---|---|---|
| 2026-10-08 | Swift, macOS 14+, Apple Silicon only | Native APIs; SwiftUI app later shares `NeutronCore` |
| 2026-10-08 | Open source, MIT | Easy contribution; Wine/DXMT/GPTK keep their own licences |
| 2026-10-08 | Register runtimes in place (no downloads yet) | Download sources and layouts need confirming in Phase 0 |
| 2026-10-08 | Backends through WINEDLLPATH, not file copies | Clean, swappable prefixes; pending Phase 0 verification |
| 2026-10-08 | JSON for internal state, TOML planned for the game database | No dependencies now; TOML is easier for contributors to edit |
