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

`tools/d3dprobe` creates a D3D11 device (or D3D12 with argument `12`, or D3D9 with `9`,
which also clears and presents to a hidden window) and prints the adapter and loaded modules, so a backend can be checked without a game. It needs
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
| d3dprobe64/32 `9` | M1 / 15.5 | Gcenx 11.18 + `tools/wine-dxmt` | wined3d | D3D9 HAL device, clear + present ok ("NVIDIA GeForce 6800") |
| d3dprobe64/32 `9` | M1 / 15.5 | Sikarugir CX 24.0.7_7 | wined3d | D3D9 HAL device, clear + present ok ("NVIDIA GeForce 8800 GTX") |
| d3dprobe64/32 | M1 / 15.5 | Gcenx 11.18 + `tools/wine-dxmt`, Sikarugir CX 24.0.7_7 | dxmt v0.80 | Device at FL 11.0, "Apple M1" |
| d3dprobe64 `12` | M1 / 15.5 | Sikarugir CX 24.0.7_7 | d3dmetal (GPTK 3.0-3) | D3D12 device created |

These only show that device creation works, not that games run.

### Windows Steam (Phase 3 groundwork, 2026-10-09)

`SteamSetup.exe /S` (from `cdn.cloudflare.steamstatic.com/client/installer/`) installs into
a prefix in seconds, and the first `Steam.exe` run downloads and installs the client
(~1.4 GB), then restarts itself ("Update complete, launching Steam..."). After that:

| Wine | Backend / flags | Result |
|---|---|---|
| Gcenx 11.18 + `tools/wine-dxmt` | wined3d (default) | "Sign in to Steam" window (700×440) appears but is **solid black**; `cef_log.txt` shows the login page's JS running |
| same | wined3d, `-cef-disable-gpu -cef-disable-gpu-compositing -no-cef-sandbox` | Same black window |
| same | dxmt | Login window created but never shown (`webhelper.txt`: position 805240832,805240832, i.e. `CW_USEDEFAULT` misread) |
| Sikarugir CX 24.0.7_7 | wined3d | steamwebhelper starts; no login window within 2 minutes |

Steam's own logs (`Steam/logs/webhelper.txt`, `cef_log.txt`) are the place to start. Note
the updater exits and relaunches Steam, so the launched process "ends" after updating.

### Diagnoses (2026-10-09)

- **Timberborn** (Unity 6000.5): the hang is its 110 s intro video. With the video moved
  aside the game reaches its menu on DXMT (mouse works on Wine 11). Video playback needs
  GStreamer for Wine's Media Foundation: `DYLD_FALLBACK_LIBRARY_PATH` and
  `GST_PLUGIN_SYSTEM_PATH_1_0` pointing at a GStreamer 1.28 framework (the Sikarugir
  Template's works), plus `GST_REGISTRY_FORK=no` and a writable `GST_REGISTRY_1_0`, since that
  framework has no `gst-plugin-scanner`. The first run spends about 75 s building the
  registry. Then the pipeline runs, but on DXMT Unity logs "Got null handle from
  IDXGIResource::GetSharedHandle" and the video never shows: DXMT only returns shared
  handles for textures created with `D3D11_RESOURCE_MISC_SHARED` (see DXMT #92, partial;
  #135 "No cutscenes" looks like the same class). On D3DMetal (CrossOver 24) the video plays,
  confirmed by the user watching it, but Wine 9 has no Unity 6 mouse input. No setup gives
  both yet.
- **Database Detective**: the desktop install is the Linux build plus a stray Windows exe:
  `copOS_Data/Plugins` has `lib_burst_generated.so` and the managed BCL wants `System.Native`.
  The Windows build can't be judged from it.
- **"A game about sucking … Demo"**: renders identically on DXMT and DXVK (two ghost sprites
  on black), so it's the game's own (likely transparent-overlay) scene, not a backend gap.
- **Steam's black sign-in window** matches DXMT issue #141: Chromium's ANGLE
  `SwapChain11::reset` fails with `EGL_BAD_ALLOC` on DXMT. On wined3d, ANGLE gets only FL 9.3.

### DXVK-macOS (fourth-backend check, 2026-10-09)

Gcenx/DXVK-macOS `v1.10.3-20230507-repack` `-builtin` ships builtin-marked
`{x86_64,i386}-windows/{d3d11,d3d10core}.dll` but no `dxgi.dll`. Composed by hand onto the
patched Wine 11.18, `d3dprobe` gets "D3D11CoreCreateDevice: Adapter is not a DXVK adapter"
and hangs: DXVK's d3d11 needs DXVK's dxgi (CrossOver's dxgi presumably provides the hook).
The full release includes `dxgi.dll` as a native (non-builtin) DLL, which Wine won't load
from `lib/wine`. A DXVK backend would need either a builtin DXVK build with dxgi or
native DLLs in the prefix (against the current design).

Follow-up: the full release works on Wine 11 as native DLLs (D3D11 device, FL 11.0, Apple
M1). Writing the "Wine builtin DLL" marker at offset 0x40 (the DOS stub, as winebuild
`--builtin` does) into **copies** of its DLLs lets them be overlaid in a composed runtime:
64-bit works, 32-bit fails (`0x80004005`). No tested game renders better on DXVK than on
DXMT yet, so the backend isn't added.

### Godot

Godot executables contain `https://godotengine.org` and a version string such as
`4.5.1.stable.mono.official`; no graphics DLLs are imported. Godot 4's default driver fails
under Wine (it falls back to the OpenGL Compatibility renderer), while
`--rendering-driver vulkan` runs Forward+ through Wine's Vulkan and MoltenVK. Godot 3 is
OpenGL-only. Library: Fortune Mill (4.5.1), You Know The Drill Demo (4.4.1), Cosmos Kitten
(3.5.3).

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
  Steam-integrated Unreal games need Phase 3 (Windows Steam in the prefix). So far 3 of 14
  launched games need the Steam client (Needle In A Haystack, ASTRONEER, CATR), which makes
  Phase 3 the biggest remaining blocker.
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

### Smoke baseline

`tools/smoke/smoke.sh` per game (patched Gcenx 11.18 + DXMT v0.80, M1, macOS 15.5);
see the games table for details. 2026-10-09:

| Result | Game | Non-black % |
|---|---|---|
| PASS | Loop Tower Demo, Desktop Defender, SNAKE FARM, Dark Deity, A Game About Digging A Hole | 98–100 |
| PASS | Fortune Mill | 81 |
| PASS | Berry Bounce | 45 |
| PASS | Cosmos Kitten, You Know The Drill Demo (dark title screens) | 13–17 |
| FAIL | Idle Colony | error dialog "Wine C++ Runtime Library" |
| FAIL | CATR | relaunches through Steam (needs the Steam client) |

### Library batch (2026-10-09)

`~/neutron-games/scripts/batch.sh`-style run: copy each game, `neutron detect`, smoke test
on patched Gcenx 11.18 + DXMT v0.80 (45–70 s), delete. 32 games, **26 PASS**:
Cursorblade, My Pet Femboy, Femboy Fury (GameMaker); Toilet Paper Idle, Stream Avatars,
OneBit Adventure, Farmer Against Potatoes Idle, IncreKnight, GrassChopper, Idle Hero TD,
BALL x PIT, Game About Botting in an MMORPG, Wireframe Racing, Wireframe Warfare, Forage
Wizard, Apple Picker, Gridle, Souper Game, One Btn Bosses, PlateUp, PEAK, Tropical Monster
Girls, Death's Door, Erenshor, Oxygen Train (Unity 2019–6000.3); Deep Rock Galactic (UE4
stub → `-dx11`, no Steam relaunch).

Failures:
- **Database Detective** (Unity 6000.5): `-force-d3d11` → "Forced GfxDevice 'Direct3D 11'
  was not built from editor … InitializeEngineGraphics failed". The build ships no D3D11
  shaders. Without the flag Unity falls back to OpenGL ("4.1 Metal") and then fails on .NET
  `System.Native`; this install mixes Windows and Linux files (`copOS.x86_64`,
  `UnityPlayer.so`), so it can't be judged here. **Neutron no longer forces D3D11 for Unity**:
  without the flag Unity tries D3D12, which fails here ("failed to create D3D12 device
  (0x80004002)"), and falls back to D3D11 on DXMT by itself (Berry Bounce, Deep Rock Survivor).
- **Timberborn** (Unity 6000.5, BepInEx mods installed): D3D11 on DXMT works, then the game
  hangs at the start of its 110 s intro video. Media Foundation fails
  (`WindowsVideoMedia error 0xc00d36bb`) because Gcenx's `winegstreamer.so` needs GStreamer
  1.28 (`@rpath`, `/Library/Frameworks/GStreamer.framework/Libraries`). Pointing
  `DYLD_FALLBACK_LIBRARY_PATH` and `GST_PLUGIN_SYSTEM_PATH_1_0` at the Sikarugir Template's
  GStreamer.framework (x86_64, 1.28) removes the error, but the game still hangs there.
- **Deep Rock Survivor** (Unity 6000.4): D3D11 on DXMT; black after `SteamAPI_Init() failed`
  in its platform-service code. Likely needs the Steam client.
- **Legends of Idleon**: Electron 11 (Chromium 87); exits. See Electron below.
- **SUPERHOT VR**: needs a VR runtime (expected).
- **Novus Orbis**: still on the "Made with Unity" splash at 70 s (renders; slow start).
- A game about sucking … Demo (Unity 6000.3): renders ghost sprites on a black scene at 60 s;
  DXMT logs `Not supported feature: 11/12/13` (D3D9-instancing/marker/D3D9-options queries).
  Unverified.
- Novus Orbis passes given 150 s. Legends of Idleon (Electron 11 + greenworks) quits
  silently with or without `--no-sandbox`/`--disable-gpu`: it needs the Steam client.

**Larger games** (same setup, copied one at a time):

| Result | Game | Notes |
|---|---|---|
| PASS | Last Man Sitting (UE5), SpongeBob SquarePants: Titans of the Tide (UE5, 10 GB), The Bloodline (UE 4.27, 18 GB) | Unreal stub followed; D3DMetal → DXMT fallback with `-dx11` on Wine 11 |
| FAIL | Deadzone Rogue 2 Playtest (UE5) | Exits within seconds (exe is `Deadzone2Steam`; likely a Steam relaunch) |
| FAIL | Skyrim Special Edition | Exits within seconds (Steam DRM wrapper; needs the client) |
| FAIL | Bugsnax (OpenGL: GLEW + Irrlicht) | Null-pointer read in `Bugsnax.exe` after its OpenVR probe; plausibly a missing GL ≥ 4.2 feature on macOS (unverified) |

Not tested (too big for the free disk at the time, 20–98 GB): Dark Souls III, Elden Ring
and Nightreign (Easy Anti-Cheat), Satisfactory, Palworld, Warframe, BeamNG.drive, Icarus,
Borderlands 3; Walkabout Mini Golf (14.6 GB, mainly VR). Linux-only installs on the desktop:
Valheim, Megabonk, Barony and others.

So far, across 52 launched games, 39 reach a rendered window on the patched Gcenx 11.18 +
DXMT (9 of the first 14, 27 of the 32-game batch, 3 of 6 large games). The biggest failure
class is the Steam client (7: CATR, ASTRONEER, Needle In A Haystack, Legends of Idleon,
Deep Rock Survivor, Deadzone Rogue 2, Skyrim SE), then macOS OpenGL limits, missing
DirectComposition, media playback (Timberborn) and VR.

**D3D12 on D3DMetal (Unreal 5):** A Game About Digging A Hole on the CrossOver 24 engine with
GPTK 3.0-3 renders its menu through D3D12 with `-dx12` (`d3d12.dll` loaded). Without a flag
it uses its default RHI, D3D11, which D3DMetal also runs; shipping the Agility SDK only means
D3D12 is available. Through its stub it first stopped at "The following component(s) are
required: Microsoft Visual C++ Runtime" on CrossOver 24, even in a fresh prefix and after
installing Microsoft's vc_redist 14.44.35211 (registry key present). Wine 11.18 passes that
check. Neutron now runs the Shipping exe directly for Unreal stubs (`--launch-stub` to opt
out), and the game passes on both Wines with auto settings.

Also: Wine 11's built-in D3D12 (vkd3d → MoltenVK) creates a device for `d3dprobe 12` on
plain Wine, but Unity's D3D12 init fails on it. Unreal 5 (Digging A Hole) loads D3D11 even
without `-dx11` (its default RHI); `-dx11` stays as a guard.

### Games

| Game | API | Mac / macOS | Backend | Works? | FPS | Env / fixes needed | Notes |
|---|---|---|---|---|---|---|---|
| Loop Tower Demo (GameMaker 2024.14) | D3D11 | M1 / 15.5 | dxmt v0.80 on Sikarugir CX 24.0.7_7 | **Yes**: window renders (checked by eye) | not measured | `steam_appid.txt` (4480440); Wine `--library-path` to Sikarugir Template Frameworks | Steam init fails without a Steam client, game continues. Fails to present on upstream Wine 11.18 |
| Berry Bounce (Unity 6000.3.0f1) | D3D11 (forced) | M1 / 15.5 | dxmt v0.80 on Sikarugir CX 24.0.7_7 (auto: d3dmetal → no GPTK → dxmt + `-force-d3d11`) | Renders, but **no mouse input** | not measured | `steam_appid.txt` (4454860) | Player.log: "EnableMouseInPointer failed … Call not implemented" (Wine 9 stub). `ID3D11Fence` creation fails (0x80004005), game continues |
| Berry Bounce (Unity 6000.3.0f1) | D3D11 (forced) | M1 / 15.5 | dxmt v0.80 on Gcenx 11.18 + `tools/wine-dxmt` | **Yes**: renders (screenshot), mouse clicks work (checked by hand) | not measured | `steam_appid.txt` | No `EnableMouseInPointer` error |
| Loop Tower Demo | D3D11 | M1 / 15.5 | dxmt v0.80 on Gcenx 11.18 + `tools/wine-dxmt` | **Yes**: renders (screenshot) | not measured | `steam_appid.txt` | |
| Berry Bounce (Unity 6000.3.0f1) | D3D11 (Unity's D3D12 path needs D3D11On12) | M1 / 15.5 | d3dmetal (GPTK 3.0-3) on Sikarugir CX 24.0.7_7 | Renders (screenshot); no mouse input (Wine 9) | not measured | `steam_appid.txt` | Adapter "AMD Compatibility Mode" |
| Desktop Defender (Unity 2022.3.62f2) | D3D11 (`-force-d3d11`) | M1 / 15.5 | dxmt v0.80 on Gcenx 11.18 + `tools/wine-dxmt` | **Yes**: renders (window screenshot) | not measured | `steam_appid.txt` | Streaming web videos fails (`WindowsVideoMedia error 0xc00d36bb`); game continues |
| SNAKE FARM (Unity 2021.3.45f2) | D3D11 (`-force-d3d11`) | M1 / 15.5 | dxmt v0.80 on Gcenx 11.18 + `tools/wine-dxmt` | **Yes**: title screen renders | not measured | `steam_appid.txt` | |
| Fortune Mill (Godot 4.5.1 Mono) | Vulkan (`--rendering-driver vulkan`) | M1 / 15.5 | none (Wine's Vulkan → MoltenVK) on Gcenx 11.18 + `tools/wine-dxmt` | **Yes**: "Vulkan 1.2.323 - Forward+ - Apple M1", menu renders | not measured | `steam_appid.txt` | Without the flag Godot's default driver fails and it falls back to "OpenGL API 4.1 Metal - Compatibility" (also renders) |
| Cosmos Kitten Demo (Godot 3.5.3 Mono) | OpenGL | M1 / 15.5 | none on Gcenx 11.18 + `tools/wine-dxmt` | **Yes**: start screen renders | not measured | `steam_appid.txt` | |
| Idle Colony (custom, SDL + OpenGL) | OpenGL | M1 / 15.5 | none on Gcenx 11.18 + `tools/wine-dxmt` | **No**: "Cannot create OpenGL Context … Invalid parameter" | | | Asks for a GL context macOS can't provide (macOS GL is 2.1 or core 3.2–4.1) |
| You Know The Drill Demo (Godot 4.4.1) | Vulkan (`--rendering-driver vulkan`) | M1 / 15.5 | none on Gcenx 11.18 + `tools/wine-dxmt` | **Yes**: menu renders | not measured | `steam_appid.txt` | |
| Dark Deity (GameMaker) | D3D11 | M1 / 15.5 | dxmt v0.80 on Gcenx 11.18 + `tools/wine-dxmt` | **Yes**: menu renders | not measured | `steam_appid.txt` | Picked DXMT only after ignoring the EOS SDK DLL (it imports d3d12) |
| A Game About Digging A Hole (UE5) | D3D11 (`-dx11`) | M1 / 15.5 | dxmt v0.80 on Gcenx 11.18 + `tools/wine-dxmt` (auto: d3dmetal → Wine can't run it → dxmt) | **Yes**: menu renders | not measured | `steam_appid.txt` | First Unreal 5 game running; no VC++ prompt or Steam relaunch |
| ASTRONEER (UE 4.27) | D3D11 (`-dx11`) | M1 / 15.5 | dxmt v0.80 on Gcenx 11.18 + `tools/wine-dxmt` | **No**: relaunches via `steam://run/361420` | | Steam client (Phase 3) | |
| Desktop Survivors 98 (MonoGame, .NET) | D3D11 / OpenGL | M1 / 15.5 | dxmt / none on Gcenx 11.18 + `tools/wine-dxmt` | **No** | | | DirectX build: `CreateSwapChainForComposition` (DirectComposition, for its transparent overlay) is E_NOTIMPL in DXMT. On wined3d: "does not support the HiDef profile". OpenGL build: MonoGame needs ARB/EXT_framebuffer_object, missing on macOS GL under Wine |
| CATR (Unity 2018.3.8f1) | D3D11 | M1 / 15.5 | dxmt (11.18 and CX24), d3dmetal (CX24) | **No**: relaunches via `steam://run/547480` | | Steam client (Phase 3) | Deletes its own `steam_appid.txt` on launch, so the usual workaround can't work. D3D11 device on the Apple M1 is created first |
| Terraria, Unrailed | n/a | | | Not testable | | | The desktop has their **Linux** depots: `.exe` is a .NET assembly next to `lib64/`/`linux/` folders |
| Needle In A Haystack (UE 5.3) | D3D12 | M1 / 15.5 | d3dmetal on Sikarugir CX 24.0.7_7 | **No**: relaunches via `steam://` | | VC++ registry key ≥ the build's toolset; Steam client | See "Unreal 5 prerequisites and Steam" |

Rows here become the first entries in the Phase 2 compatibility database.
