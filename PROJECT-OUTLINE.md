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
   BackendSetup ── builtin WINEDLLOVERRIDES + which backend runtime to overlay
   ComposedRuntime ── APFS clone of Wine with the backend overlaid (runtimes/composed/)
   Launcher     ── builds a LaunchPlan (pure, testable); run() composes, runs
                   `wineboot -u` if the prefix lacks the backend's DLLs, then launches
```

State root: `~/Library/Application Support/Neutron` (override with `NEUTRON_HOME`).

**Core design:** a backend is applied by launching a "composed runtime": an APFS clone of
the registered Wine build with the backend's DLLs overlaid, cached per Wine+backend pair.
Registered runtimes are never modified, and clones share disk blocks with the original.
The prefix gets the backend's DLLs through Wine's own `wineboot -u`. Phase 0 showed the
original WINEDLLPATH plan can't work (see the decision log and `docs/phase0-spike.md`).

## Phases

### Phase 0: Spike (hands-on, real hardware)
Checklist: [docs/phase0-spike.md](docs/phase0-spike.md)
- [x] First `swift build` / `swift test` on macOS (passing in CI, macos-15)
- [ ] Local build and test on both Macs *(first Mac done: M1, macOS 15.5)*
- [ ] Gather Wine (wow64 + msync), DXMT and GPTK; record their exact folder layouts
      *(Wine, DXMT and an msync CrossOver Wine done; Apple's own GPTK still needed)*
- [x] Verify the WINEDLLPATH approach for DXMT and D3DMetal, or switch to composed runtimes
      *(WINEDLLPATH fails; switched. DXMT and D3DMetal both verified; D3DMetal needs a
      CrossOver-era Wine)*
- [ ] Run one D3D9, D3D11, D3D12 and 32-bit game; fill in the results table
      *(D3D11 done: Loop Tower Demo on DXMT)*
- [x] Check whether Unreal stub exes need detection to follow `Binaries/Win64/*-Shipping.exe`
      *(yes: stubs import no graphics DLLs and fall back to wined3d)*

### Phase 1: CLI runtime and prefix manager *(scaffolded)*
- [x] `runtime add/list/remove`: register on-disk runtimes
- [x] `prefix create/list/delete/set-backend/set-env`
- [x] `detect`: PE import scan of exe and sibling DLLs → backend recommendation
- [x] Engine-aware detection: Unity/Unreal, Unreal stub following, Agility SDK, engine
      D3D11 flags, GPTK→DXMT fallback, middleware filtering
- [x] Godot detection (Godot 4 → Vulkan through MoltenVK)
- [x] `run`: launch with auto/explicit backend, `--hud`, `--debug`, `--dry-run`
- [x] `wine`: raw Wine commands in a prefix
- [ ] Fix whatever Phase 0 finds (layouts, load paths) *(Wine/DXMT layouts and loading done; GPTK pending)*
- [x] Log files per launch (`logs/<prefix>/<timestamp>-<exe>.log`) echoed to the terminal
- [x] `neutron doctor`: check for Rosetta, runtimes, macOS version and common problems
      (also each Wine's DXMT/D3DMetal/msync support and missing wrapper libraries)
- [x] `neutron kill`: stop a prefix's Wine processes with the right `wineserver -k`
- [x] Unreal prerequisites: VC++ runtime check (bypassed by running the Shipping exe)
- [ ] DXVK + MoltenVK as a fourth backend (for D3D11 games DXMT can't handle)
      *(Gcenx's DXVK-macOS 1.10.3 `-builtin` repack has no `dxgi.dll`; with Wine's dxgi it
      logs "Adapter is not a DXVK adapter" and hangs. The full release has `dxgi.dll` but
      isn't builtin-marked; marking copies works for 64-bit. No game needs it yet; see spike doc)*

### Phase 2: Compatibility database
- [ ] Schema: `games/<steam-appid or exe-hash>.toml` with backend, env, DLL overrides,
      winetricks verbs, launch args, status (platinum/gold/…), notes, tested Wine/macOS versions
- [ ] Match games by Steam app ID, then by exe name + hash
- [ ] Apply entries automatically in `run`, with `--no-db` to bypass
- [ ] `neutron report`: produce a result entry (env, versions, outcome) for a PR
- [ ] Seed with Phase 0 results

### Phase 3: Steam integration
- [ ] Cross-process presentation, the prerequisite for Steam's UI: Steam's Chromium GPU process
      creates its D3D11 swap chain on a `Chrome_WidgetWin_1` child window owned by the browser
      process, which DXMT refuses and winemac can't show (window surfaces are per process).
      Plan, mirroring how Chrome does it natively on macOS:
      1. DXMT (renderer side): when the window belongs to another process, create the
         `CAMetalLayer` in a `CAContext` (remote layer) and send its context ID to the window.
      2. winemac (owner side): a driver message that hosts the context with a `CALayerHost` in
         the child window's view, tracking its frame, visibility and clipping.
      3. Teardown when either process goes away. Uses private Core Animation API, like Chrome.
      Upstream DXMT and Wine are the right home; prototype in `tools/` patches first.
- [ ] `neutron steam install`: Windows Steam in a shared prefix
      *(installs and updates; the sign-in window renders black until the item above lands)*
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
      *(`tools/smoke/smoke.sh` does one game locally; still needs a game list and CI/runner)*

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
| 2026-10-08 | **Replaced** WINEDLLPATH with composed runtimes (APFS clone of Wine + backend overlay) and `wineboot -u` to install the backend's DLLs into the prefix | Phase 0: Wine searches its own `lib/wine` before WINEDLLPATH, so Wine's d3d11/dxgi win, and it won't load a builtin (winemetal.dll) that has no copy in the prefix. The composed build ran DXMT at FL 11.0 on 64- and 32-bit. The clone takes ~1 s and shares disk blocks |
| 2026-10-08 | Dropped the DYLD_FALLBACK_* env for D3DMetal; overlay GPTK's `external/` to `lib/external` instead | Mirroring GPTK's layout should let its relative library paths resolve; unverified until GPTK is tested. (The original reason, "DYLD_* doesn't reach Wine", was **wrong**: the test ran through SIP-protected `/usr/bin/perl`, which strips DYLD_*. Revisit if the overlay alone isn't enough.) |
| 2026-10-08 | DXMT requires a CrossOver-based Wine; Wine runtimes can carry `libraryPaths` (→ `DYLD_FALLBACK_LIBRARY_PATH`) | Upstream Wine 11.18 creates a DXMT device but can't present ("no exported symbols needed by DXMT"): winemac doesn't export `macdrv_functions`. Sikarugir's CrossOver 24.0.7 engine exports it and runs Loop Tower Demo on DXMT, but needs its wrapper's `Frameworks` dylibs |
| 2026-10-08 | Ship a Wine patch + script (`tools/wine-dxmt`) that rebuilds only `winemac.so` with an exported `macdrv_functions` table, instead of relying on CrossOver-based builds | The only DXMT-capable builds available (CrossOver 24 engines) are Wine 9-based and lack `EnableMouseInPointer`, so Unity 6 games get no mouse input. Wine 11.18 has it; patching one unix library of a Gcenx build keeps everything else stock and takes ~1 minute. Neutron still doesn't download or bundle Wine |
| 2026-10-08 | Gate backends on what the Wine build exports (`WineCapabilities`): DXMT needs `winemac.so` → `macdrv_functions`; D3DMetal also needs `ntdll.dll` → `__wine_unix_call`. Auto mode falls back to DXMT, explicit choices warn | D3DMetal (GPTK 3.0) only runs on CrossOver-era Wine (≤ 9); on Wine 11 it can't load, and even with the export restored it crashes on thread-register handling. Checking exports beats version numbers, since builds patch these independently |
| 2026-10-09 | Run an Unreal stub's `*-Shipping.exe` directly (`--launch-stub` to opt out) | The stub only checks the VC++ runtime and relaunches; that check fails on CrossOver-based Wine even with vc_redist 14.44 installed, blocking Unreal 5 on D3DMetal. Running the Shipping exe works on both Wines |
| 2026-10-09 | Stop forcing `-force-d3d11` for Unity | Some Unity 6 builds ship no D3D11 shaders, and forcing D3D11 makes them fail to start (Database Detective). Without the flag Unity tries D3D12, which fails under these Wines, and falls back to D3D11 on DXMT by itself |
| 2026-10-08 | Unity games always go to DXMT; the Agility SDK rule now applies to Unreal only | Unity's D3D12 renderer needs D3D11On12, which D3DMetal lacks: Unity 6 logs "failed to create D3D11On12 device" and falls back to D3D11 there |
| 2026-10-08 | The GPTK overlay takes only D3DMetal's files (unix libraries that link into `external/`, their DLLs, `external/`) | Registering a whole Wine build as GPTK (Gcenx's game-porting-toolkit) overlaid its Wine 7.7 `ntdll.so` etc. onto Wine 11 and broke it |
| 2026-10-08 | Count managed Direct3D wrappers (`SharpDX.*`/`Vortice.*` `.Direct3D9/10/11/12.dll`) as imports | .NET games (MonoGame DirectX) P/Invoke Direct3D, so import tables show nothing and they fell to wined3d, whose fake adapter fails MonoGame's HiDef check (Desktop Survivors 98) |
| 2026-10-08 | Detect Godot; Godot 4 gets `--rendering-driver vulkan` and no Direct3D backend | Godot imports no graphics DLLs. Under Wine its default driver fails and it drops to the OpenGL Compatibility renderer; Vulkan (Wine's winevulkan → MoltenVK) runs Forward+ (Fortune Mill) |
| 2026-10-08 | Engine-aware detection (Unity, Unreal): the D3D12 Agility SDK decides d3dmetal (DXMT fallback when no GPTK), otherwise DXMT; backends without D3D12 get the engine's `-force-d3d11` / `-dx11` | Unity and Unreal import both d3d11 and d3d12 (or neither: many UnityPlayer.dll builds import only opengl32), so imports can't tell. Across 38 Unity installs and 11 Unreal games the Agility SDK appeared only in Unity 6 and UE5 builds. These flags are engine-wide rules, not per-game workarounds, so they live in code. Unreal stubs are followed to `*-Shipping.exe`; middleware DLLs (EOS, CEF) are ignored since they import d3d12 for overlays |
| 2026-10-09 | Wine runtimes can carry a GStreamer install (`--gstreamer`): Neutron sets the dylib fallback path, plugin path and a per-runtime registry under `runtimes/gstreamer/`, and `Launcher.run` refreshes that registry by running the install's `gst-inspect-1.0` natively before Wine | Media Foundation video (Unity, Unreal intros) goes through winegstreamer, which Gcenx builds link against GStreamer 1.28 by `@rpath`. Wine starts GStreamer with `--gst-disable-registry-fork`, so without a pre-built registry every plugin (Python, Vulkan with a second MoltenVK, …) loads inside the game, and on Timberborn the first scan took ~75 s; natively it takes ~2 s and the game loads only the dozen plugins it uses. Users install the official framework; Neutron doesn't bundle it |
| 2026-10-09 | Games importing both d3d12 and d3d11 get d3dmetal with a dxmt fallback | Warframe imports both and has a D3D11 renderer; without GPTK (or on Wine 10+) auto mode errored instead of using DXMT. D3D12-only games (Elden Ring) still require D3DMetal |
| 2026-10-09 | An exe with no graphics imports and no engine is treated as a launcher: the exe one or two folders below it (name match first, then size; tools skipped) decides the backend | BeamNG.drive's launcher imports nothing and starts `Bin64/BeamNG.drive.x64.exe` (D3D11/12), which inherited the launcher's wined3d. Only BeamNG changed across the library scan |
| 2026-10-09 | Ship a DXMT patch + script (`tools/dxmt-patch`) that rebuilds only the Windows-side DLLs from the release's tag | DXMT fills timestamp queries in on its finish thread, after later event queries have signalled from the GPU; UE5's D3D11 clock calibration reads them in that window and asserts (Satisfactory). Rebuilding three PE DLLs with mingw-gcc avoids DXMT's LLVM 15 toolchain; winemetal and the unix side stay as released. Worth upstreaming |
| 2026-10-09 | Prefixes can pin DXMT/GPTK versions (`runtimeVersions`, `prefix set-runtime`), not just Wine | Comparing DXMT v0.80 with a main build for Satisfactory meant unregistering runtimes; "newest" is decided by version label, so a build named `dxmt-main-…` never won anyway |
| 2026-10-09 | Patch a winemac lock-order deadlock in `tools/wine-dxmt` (`winemac-flush-deadlock.patch`) | Wine 11's `macdrv_surface_flush` blocks on `win_data_mutex` under win32u's user lock while `macdrv_WindowPosChanged` takes them in the opposite order: Unreal splash + main window creation deadlocked (Deep Rock Galactic). Worth reporting upstream; until then it rides along with the DXMT patch since both rebuild only `winemac.so` |
| 2026-10-09 | `tools/wine-dxmt` also patches `mfreadwrite.dll` to hand out shareable video textures | Unity calls `GetSharedHandle` on decoded frames and stalls on DXMT's (correct, Windows-like) NULL handle for unshared textures. The patch is a Wine behaviour change for upstream, so it stays a script-applied patch on stock Gcenx builds |
| 2026-10-08 | JSON for internal state, TOML planned for the game database | No dependencies now; TOML is easier for contributors to edit |
