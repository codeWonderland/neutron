# Phase 0: Spike

Goal: on real hardware, find out exactly what it takes to run games, and confirm the guesses
Phase 1 is built on. Record results in the table at the bottom.

You have two Apple Silicon Macs. If possible, put them on **different macOS versions**
(current release and current beta, for example) so OS-specific problems show up early.

## 1. Gather runtimes

- [ ] **Wine:** a recent macOS build with wow64 (single `bin/wine`). Options: Gcenx's builds
      (`brew install --cask --no-quarantine gcenx/wine/wine-crossover` or the
      macOS_Wine_builds releases), or CrossOver's open-source Wine. Note which build has msync.
  - Builds tried so far (2026-10-08):

    | Build | Base | wow64 | msync | DXMT symbols | Notes |
    |---|---|---|---|---|---|
    | Gcenx wine-devel 11.18 | Wine 11.18 | yes | no | none exported | Device only, can't present |
    | Gcenx game-porting-toolkit 3.0-3 (cask tarball) | Wine 7.7 (GPTK 1.1) | no (`wine64`) | no | none | **Ships D3DMetal** in `lib/external`; layout matches Neutron's gptk guess |
    | Sikarugir `WS12WineSikarugir11.0_1` | Wine 11.0 | yes | yes | `macdrv_functions` | Wine processes fail to start outside the Sikarugir wrapper ("failed to start wineboot 1") |
    | Sikarugir `WS12WineCX24.0.7_7` | CrossOver 24.0.7 (Wine 9.0) | yes | yes | `macdrv_functions` | **Works with DXMT.** Needs the wrapper's dylibs: `runtime add wine <engine> --library-path <Template.app>/Contents/Frameworks` (Sikarugir-App/Template releases). `EnableMouseInPointer` is a stub, so Unity 6 games get no mouse input |
    | Gcenx wine-devel 11.18 + `tools/wine-dxmt` | Wine 11.18 | yes | no | `macdrv_functions` (patched) | **Works with DXMT**, and has Wine's 2026 `EnableMouseInPointer`/pointer-message support. Only `winemac.so` is rebuilt |

    Why a patch and not just "export the symbols": DXMT reads `client_cocoa_view` as the
    4th field of `struct macdrv_win_data` (CrossOver's layout). Wine 11's struct is
    `{hwnd, cocoa_window, client_view, rects, …}`, and `client_view` is only set for GL/Vulkan
    surfaces. `winemac-dxmt.patch` exports a `macdrv_functions` table whose `get_win_data`
    returns a copy in DXMT's layout and whose `create_metal_view` adds a fresh (uncached)
    Metal view to the window's content view.

    Sikarugir engines extract to `<name>/wswine.bundle/{bin,lib/wine}`. Their wrapper also
    sets `WINEDLLPATH_PREPEND` (a Sikarugir Wine patch that searches a DLL folder before
    Wine's own), `ROSETTA_ADVERTISE_AVX`, `DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN` and others.
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
- [x] `DYLD_*` variables **do** reach Wine when Neutron launches it. (An earlier note said
      they didn't; that test ran through `/usr/bin/perl`, and macOS strips DYLD_* when
      launching SIP-protected binaries. Don't wrap Wine in system binaries when testing.)
- [x] **DXMT needs a CrossOver-based Wine.** With upstream Gcenx Wine 11.18 a game creates
      its device but every frame fails with "Failed to create metal view, it seems like your
      Wine has no exported symbols needed by DXMT". DXMT's `winemetal.so` looks up
      `macdrv_functions` (or the `macdrv_view_*_metal_*` functions) in `winemac.so`
      (`nm -gU winemac.so | grep macdrv_` to check). `d3dprobe` only creates a device, so it
      can't catch this; check with a real windowed game.
- [x] **D3DMetal works through Neutron on a CrossOver-based Wine** (Sikarugir CX 24.0.7,
      D3DMetal from Gcenx's game-porting-toolkit 3.0-3 build): `d3dprobe64.exe 12` creates
      a D3D12 device, D3D11 runs too (adapter "AMD Compatibility Mode"), and Berry Bounce
      renders. Layout: `lib/wine/x86_64-unix/{d3d10,d3d11,d3d12,dxgi,nvapi64,nvngx,
      nvngx-on-metalfx,atidxx64}.so` are symlinks to `../../external/libd3dshared.dylib`,
      which loads `external/D3DMetal.framework`; the matching PE DLLs sit in
      `lib/wine/x86_64-windows`. Neutron overlays only those files plus `external/`.
- [x] **D3DMetal does not run on Wine 10+.** Its DLLs import `ntdll.__wine_unix_call`, which
      Wine dropped (11.18 has only `__wine_unix_call_dispatcher`). Re-exporting it gets
      D3DMetal loading, but it then crashes in `pthread_self`/`pthread_setname_np` (null
      thread pointer): it expects the older thread-register handling. Neutron now reads each
      Wine build's exports (`WineCapabilities`) and falls back to DXMT when the Wine can't
      run D3DMetal.
- [x] **Unity doesn't get D3D12 from D3DMetal.** Unity 6 tries D3D12 first and logs
      "failed to create D3D11On12 device (0x887a0004)", then falls back to D3D11. So Unity
      games always go to DXMT; only Unreal games with the Agility SDK prefer D3DMetal.

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

### Unreal 5 prerequisites and Steam (Needle In A Haystack, UE 5.3)

- The stub (`BootstrapPackagedGame`) checks
  `HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64` (`Major`/`Minor`/`Bld`/
  `Rbld`), `msvcp140_2.dll`, `vcruntime140_1.dll` and `XINPUT1_3.DLL`, and otherwise shows
  "The following component(s) are required… Microsoft Visual C++ Runtime". Wine provides the
  DLLs but not the registry key. The game's own `Engine/Extras/Redist/en-us/UEPrereqSetup_x64.exe
  /quiet` installs VC++ 14.36, still below what this build wants; the check passed only with
  a newer version in the registry. Candidate for the Phase 2 database (or an engine rule).
- After that the Shipping exe calls `steam://run/<appid>` and exits, even with
  `steam_appid.txt` beside it: Unreal's Steam subsystem relaunches through the Steam client.
  Steam-integrated Unreal games need Phase 3 (Windows Steam in the prefix).
- The CrossOver engine runs Wine processes from `$TMPDIR/winetemp-*`; `pkill wineserver`
  doesn't stop them. `neutron kill` (the runtime's own `wineserver -k`) does.

### Detection scan

`neutron detect` on every exe in a 105-game Steam library (164 exes; exe + sibling DLLs
copied off a Linux desktop). The PE parser handled every real Windows exe. Findings:

- Unity games import d3d11 **and** d3d12 through `UnityPlayer.dll`; Unreal `-Shipping.exe`
  files do too. Both engines choose the API at runtime, so these all get `d3dmetal`.
  Unity 6 (e.g. Berry Bounce, 6000.3) may really default to D3D12; older Unity and UE4
  default to D3D11. Detection needs engine awareness (and `-force-d3d11` / `-dx11`).
- Unreal root exes (`FSD.exe`, `Astro.exe`, `DiggingGame.exe`…) are stubs with no graphics
  imports → `wined3d`. Detection must follow `<Game>/Binaries/Win64/*-Shipping.exe`.
- Some Linux-native installs keep a `.exe` name on an ELF binary (dotAge, Vampire
  Survivors); `detect` rejects them correctly ("missing MZ header").
- Steam games call `SteamAPI_Init`; add `steam_appid.txt` (the app ID) next to the exe.
  GameMaker's Steamworks extension deletes that file on every launch.

After engine-aware detection (same library; folder structure, Agility SDK files and
Unity data headers mirrored; 34 Unity and 11 Unreal games): 27 Unity 6 / UE5 games with the Agility SDK → `d3dmetal`
with a DXMT fallback; 18 Unity 2018–2023 / UE4 games (and Unity 6 builds without the SDK) → `dxmt` with `-force-d3d11` /
`-dx11` (previously most went to wined3d or d3dmetal); Dark Deity (GameMaker) → `dxmt`
once the EOS SDK DLL is ignored. Still unhandled: Godot and other engines that load their
renderer at runtime (Fortune Mill, CosmosKitten…) fall to wined3d.

### Games

| Game | API | Mac / macOS | Backend | Works? | FPS | Env / fixes needed | Notes |
|---|---|---|---|---|---|---|---|
| Loop Tower Demo (GameMaker 2024.14) | D3D11 | M1 / 15.5 | dxmt v0.80 on Sikarugir CX 24.0.7_7 | **Yes**: window renders (checked by eye) | not measured | `steam_appid.txt` (4480440); Wine `--library-path` to Sikarugir Template Frameworks | Steam init fails without a Steam client, game continues. Fails to present on upstream Wine 11.18 |
| Berry Bounce (Unity 6000.3.0f1) | D3D11 (forced) | M1 / 15.5 | dxmt v0.80 on Sikarugir CX 24.0.7_7 (auto: d3dmetal → no GPTK → dxmt + `-force-d3d11`) | Renders, but **no mouse input** | not measured | `steam_appid.txt` (4454860) | Player.log: "EnableMouseInPointer failed … Call not implemented" (Wine 9 stub). `ID3D11Fence` creation fails (0x80004005), game continues |
| Berry Bounce (Unity 6000.3.0f1) | D3D11 (forced) | M1 / 15.5 | dxmt v0.80 on Gcenx 11.18 + `tools/wine-dxmt` | **Yes**: renders (screenshot), mouse clicks work (checked by hand) | not measured | `steam_appid.txt` | No `EnableMouseInPointer` error |
| Loop Tower Demo | D3D11 | M1 / 15.5 | dxmt v0.80 on Gcenx 11.18 + `tools/wine-dxmt` | **Yes**: renders (screenshot) | not measured | `steam_appid.txt` | |
| Berry Bounce (Unity 6000.3.0f1) | D3D11 (Unity's D3D12 path needs D3D11On12) | M1 / 15.5 | d3dmetal (GPTK 3.0-3) on Sikarugir CX 24.0.7_7 | Renders (screenshot); no mouse input (Wine 9) | not measured | `steam_appid.txt` | Adapter "AMD Compatibility Mode" |
| Needle In A Haystack (UE 5.3) | D3D12 | M1 / 15.5 | d3dmetal on Sikarugir CX 24.0.7_7 | **No**: relaunches via `steam://` | | VC++ registry key ≥ the build's toolset; Steam client | See "Unreal 5 prerequisites and Steam" |

Rows here become the first entries in the Phase 2 compatibility database.
