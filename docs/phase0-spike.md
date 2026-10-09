# Phase 0: Spike

Goal: on real hardware, find out exactly what it takes to run games, and confirm the guesses
Phase 1 is built on. Record results in the table at the bottom.

You have two Apple Silicon Macs. If possible, put them on **different macOS versions**
(current release and current beta, for example) so OS-specific problems show up early.

## 1. Gather runtimes

- [ ] **Wine:** a recent macOS build with wow64 (single `bin/wine`). Options: Gcenx's builds
      (`brew install --cask --no-quarantine gcenx/wine/wine-crossover` or the
      macOS_Wine_builds releases), or CrossOver's open-source Wine. Note which build has msync.
- [ ] **DXMT:** latest release from github.com/3Shain/dxmt. Write down its folder layout.
- [ ] **Game Porting Toolkit:** download from developer.apple.com (free Apple ID). Write down
      where `redist/lib/external/D3DMetal.framework` and `redist/lib/wine/` are.
- [ ] Install Rosetta: `softwareupdate --install-rosetta`.

## 2. Confirm the core assumption: WINEDLLPATH loading

Neutron applies DXMT and D3DMetal through `WINEDLLPATH` and builtin overrides, not by
copying files into Wine. This is the biggest unknown.

```sh
swift build && alias neutron="$PWD/.build/debug/neutron"
neutron runtime add wine <wine>   && neutron runtime add dxmt <dxmt>   && neutron runtime add gptk <gptk>
neutron prefix create spike
neutron run <d3d11 game>.exe -p spike --backend dxmt --debug +loaddll
```

- [ ] With `+loaddll`, are `d3d11.dll`/`dxgi.dll` loaded from the DXMT directory?
- [ ] Is `winemetal.so` (DXMT's unix side) found under `x86_64-unix`?
- [ ] Same for D3DMetal: does `d3d12.dll` load from GPTK, and does its `.so` find
      `D3DMetal.framework` through `DYLD_FALLBACK_FRAMEWORK_PATH`?
- [ ] **If not:** the fallback is a "composed runtime": a copy (or APFS clone, `cp -c`) of the
      Wine build with the backend overlaid. Record exactly which files go where.

## 3. Test games

Pick free or already-owned games covering each API:

| API | Suggested test game |
|---|---|
| D3D9 | an older indie title, e.g. from GOG |
| D3D11 | a Unity or Unreal 4 game |
| D3D12 | a recent Unreal 5 game, or a D3D12-only title |
| 32-bit | any old 32-bit exe (tests wow64) |
| Launcher | Windows Steam itself |

For each game, try every backend that applies and note the results.

- [ ] Does `neutron detect` pick the backend that actually works best?
- [ ] Unreal games: the root `.exe` is often a stub that starts
      `<Game>/Binaries/Win64/<Game>-Shipping.exe`. Does detection need to follow it?
- [ ] Does `WINEMSYNC=1` measurably help (FPS, stutter)?
- [ ] Metal HUD (`--hud`): note FPS for comparisons.

## 4. Results

| Game | API | Mac / macOS | Backend | Works? | FPS | Env / fixes needed | Notes |
|---|---|---|---|---|---|---|---|
| | | | | | | | |

Rows here become the first entries in the Phase 2 compatibility database.
