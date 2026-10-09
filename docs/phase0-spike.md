# Phase 0: Spike

Goal: on real hardware, find out exactly what it takes to run games, and confirm the guesses
Phase 1 is built on. Record results in the table at the bottom.

You have two Apple Silicon Macs. If possible, put them on **different macOS versions**
(current release and current beta, for example) so OS-specific problems show up early.

## 1. Gather runtimes

- [ ] **Wine:** a recent macOS build with wow64 (single `bin/wine`). Options: Gcenx's builds
      (`brew install --cask --no-quarantine gcenx/wine/wine-crossover` or the
      macOS_Wine_builds releases), or CrossOver's open-source Wine. Note which build has msync.
  - [x] Gcenx `wine-devel-11.18-osx64.tar.xz` (macOS_Wine_builds): wow64 (only `bin/wine`,
        x86_64 Mach-O), extracts to `wine-devel-11.18/Wine Devel.app/Contents/Resources/wine/`
        with `bin/` and `lib/wine/{x86_64-windows,i386-windows,x86_64-unix}`. Version is in
        the app's `Info.plist`. **No msync** (no msync strings in `ntdll.so`); try wine-crossover next.
- [x] **DXMT:** latest release from github.com/3Shain/dxmt. Write down its folder layout.
  - v0.80 `dxmt-v0.80-builtin.tar.gz` extracts to `v0.80/` containing
    `x86_64-windows/{d3d10core,d3d11,dxgi,winemetal,nvapi64,nvngx}.dll`,
    `i386-windows/{d3d10core,d3d11,dxgi,winemetal}.dll` and `x86_64-unix/winemetal.so`.
    All PE files carry the "Wine builtin DLL" marker.
- [ ] **Game Porting Toolkit:** download from developer.apple.com (free Apple ID). Write down
      where `redist/lib/external/D3DMetal.framework` and `redist/lib/wine/` are.
- [ ] Install Rosetta: `softwareupdate --install-rosetta`.

## 2. Confirm backend loading

`tools/d3dprobe` creates a D3D11 (or, with argument `12`, D3D12) device and prints the
adapter and loaded modules, so a backend can be checked without a game. It needs
mingw-w64 (`brew install mingw-w64`).

```sh
swift build && alias neutron="$PWD/.build/debug/neutron"
tools/d3dprobe/build.sh            # → .build/d3dprobe/d3dprobe{64,32}.exe
neutron runtime add wine <wine>   && neutron runtime add dxmt <dxmt>   && neutron runtime add gptk <gptk>
neutron prefix create spike
neutron run .build/d3dprobe/d3dprobe64.exe -p spike --backend dxmt
neutron run .build/d3dprobe/d3dprobe64.exe -p spike --backend d3dmetal -- 12
```

The adapter name tells you who answered: wined3d reports a fake "NVIDIA GeForce 6800" at
feature level 9.3, while DXMT reports the real Apple GPU.

- [x] **WINEDLLPATH doesn't work** (Wine 11.18 devel, DXMT v0.80, 2026-10-08). Wine reads
      it (`WINEDLLDIR1` in the Windows env), but `WINEDLLDIR0` is Wine's own `lib/wine`,
      which is searched first, so Wine's `d3d11.dll`/`dxgi.dll` load. And Wine only loads a
      builtin that has a copy in the prefix's `system32`/`syswow64`, so `winemetal.dll` was
      "not found" (c0000135). The probe silently got wined3d.
- [x] **Composed runtime works**: an APFS clone of the Wine root (`cp -c` or
      `FileManager.copyItem`, ~1 s, timestamps kept) with DXMT's `x86_64-windows`,
      `i386-windows` and `x86_64-unix` contents copied into `lib/wine/<same>`, then
      `wineboot -u` with that build (installs `winemetal.dll` etc. into the prefix). This is
      now what Neutron does automatically (`ComposedRuntime`).
- [x] Switching the same prefix back to wined3d after DXMT still works: the prefix's
      copies are builtin-marked, so Wine loads them from whichever build is running.
- [x] `DYLD_*` variables (tested `DYLD_PRINT_LIBRARIES`) don't reach Wine's processes,
      so D3DMetal can't rely on `DYLD_FALLBACK_FRAMEWORK_PATH`.
- [ ] D3DMetal: with GPTK registered, does `d3dprobe64.exe 12` create a device? Neutron
      overlays `redist/lib/wine/*` into `lib/wine/` and `redist/lib/external/` into
      `lib/external/`. Check with `otool -L` how GPTK's `.so` files find `D3DMetal.framework`.

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

### Backend probe (`tools/d3dprobe`)

| Probe | Mac / macOS | Wine | Backend | Result |
|---|---|---|---|---|
| d3dprobe64 | M1 / 15.5 | Gcenx devel 11.18 | wined3d | Device at FL 9.3, adapter "NVIDIA GeForce 6800" (fake) |
| d3dprobe64 | M1 / 15.5 | Gcenx devel 11.18 | dxmt v0.80 (WINEDLLPATH, old design) | Silently fell back to wined3d |
| d3dprobe64 | M1 / 15.5 | Gcenx devel 11.18 | dxmt v0.80 (composed) | Device at FL 11.0, adapter "Apple M1" |
| d3dprobe32 | M1 / 15.5 | Gcenx devel 11.18 | dxmt v0.80 (composed) | Device at FL 11.0, adapter "Apple M1" (wow64 works) |

These only show that device creation works, not that games run.

### Games

| Game | API | Mac / macOS | Backend | Works? | FPS | Env / fixes needed | Notes |
|---|---|---|---|---|---|---|---|
| | | | | | | | |

Rows here become the first entries in the Phase 2 compatibility database.
