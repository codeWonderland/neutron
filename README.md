# Neutron

[![CI](https://github.com/codeWonderland/neutron/actions/workflows/ci.yml/badge.svg)](https://github.com/codeWonderland/neutron/actions/workflows/ci.yml)

**Proton-style Windows game compatibility for Apple Silicon Macs.**

Neutron doesn't reinvent the translation layers. Like Proton, it brings together the excellent
projects that already exist, then does the part that makes them feel like one product:

| Layer | Project | Role |
|---|---|---|
| Windows API | [Wine](https://www.winehq.org) | Runs Windows programs on macOS |
| D3D10/11 → Metal | [DXMT](https://github.com/3Shain/dxmt) | Fast open-source D3D11 path |
| D3D11/12 → Metal | D3DMetal (Apple's [Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/)) | D3D12 support; users supply their own copy |
| D3D9 and older | wined3d (built into Wine) | Fallback |
| x86 → ARM | Rosetta 2 | CPU translation |

Neutron's own job: **choose the right backend for each game, keep prefixes and runtimes clean
and swappable, and (soon) apply per-game fixes from a community compatibility database.**

> Status: early. Phase 1 (CLI runtime and prefix manager) is scaffolded; see the roadmap.

## What you need

Neutron doesn't ship or download anything yet. Download these yourself and register them
with `neutron runtime add`:

| What | Where to get it | Notes |
|---|---|---|
| macOS 14+ on Apple Silicon | | Plus Xcode 16 or the Swift 6 toolchain to build Neutron |
| Rosetta 2 | `softwareupdate --install-rosetta` | Runs Wine's x86_64 code |
| Wine | [Gcenx's macOS Wine builds](https://github.com/Gcenx/macOS_Wine_builds/releases) (`wine-devel-*-osx64.tar.xz`) | Works as-is for wined3d. **For DXMT, patch it** with `tools/wine-dxmt/build.sh` (below) |
| DXMT | [3Shain/dxmt releases](https://github.com/3Shain/dxmt/releases) (`dxmt-*-builtin.tar.gz`) | D3D10/11 → Metal. Point `runtime add` at the extracted folder |
| GStreamer | [gstreamer.freedesktop.org](https://gstreamer.freedesktop.org/download/#macos) (the macOS **runtime** installer, `gstreamer-1.0-*-universal.pkg`) | Optional; plays in-game videos (intros, cutscenes). Installs `/Library/Frameworks/GStreamer.framework`; pass it to `runtime add wine --gstreamer` |
| Game Porting Toolkit (D3DMetal) | [Apple Developer](https://developer.apple.com/games/game-porting-toolkit/) (free Apple ID) | Optional; for D3D12 games (Unreal 5). Never redistributed by Neutron. Only runs on a CrossOver-based Wine 9 or older (see below) |

### A Wine that works with DXMT

DXMT draws into game windows through functions in Wine's Mac driver that stock Wine builds
keep private. Without them a game starts but every frame fails with *"Failed to create metal
view, it seems like your Wine has no exported symbols needed by DXMT"*.
`tools/wine-dxmt/build.sh` makes a patched copy of a Gcenx build. It rebuilds only
`winemac.so` (with `winemac-dxmt.patch`) and `mfreadwrite.dll` (with
`mfreadwrite-shared-samples.patch`, so Unity games' videos play under DXMT) from the
matching Wine source, which takes a few minutes the first time:

```sh
brew install bison flex mingw-w64
tools/wine-dxmt/build.sh "$HOME/Downloads/wine-devel-11.18/Wine Devel.app/Contents/Resources/wine" \
    ~/Neutron/wine-11.18-dxmt
neutron runtime add wine ~/Neutron/wine-11.18-dxmt --version wine-11.18-dxmt \
    --gstreamer /Library/Frameworks/GStreamer.framework
```

Tested with Wine 11.18. Use a recent Wine (11.15 or later): Unity 6 games need its mouse
input support (`EnableMouseInPointer`). CrossOver-based builds also work with DXMT; for
example Sikarugir's `WS12WineCX24.0.7` engine from
[Sikarugir-App/Engines](https://github.com/Sikarugir-App/Engines/releases), registered
with `--library-path <Sikarugir Template.app>/Contents/Frameworks` for the libraries it
expects from its wrapper. That one is based on Wine 9, so Unity 6 games get no mouse input, but it is also the kind
of Wine D3DMetal needs: D3DMetal doesn't run on Wine 10 or later. Neutron checks what each
Wine build supports and falls back to DXMT (with a note) when it can't run D3DMetal.

## Quick start

```sh
swift build -c release
alias neutron="$PWD/.build/release/neutron"

# Register runtimes you've already downloaded (the folders the archives extract to)
neutron runtime add wine ~/Neutron/wine-11.18-dxmt --version wine-11.18-dxmt \
    --gstreamer /Library/Frameworks/GStreamer.framework   # optional: in-game video
neutron runtime add dxmt ~/Downloads/dxmt-v0.80
neutron runtime add gptk "/Volumes/Evaluation environment for Windows games 2.1"
neutron doctor                                # checks the Mac, runtimes and prefixes; says how to fix problems

# Create a prefix and run something
neutron prefix create default
neutron detect ~/Games/MyGame/MyGame.exe     # shows engine, graphics APIs and the backend it'd pick
neutron run ~/Games/MyGame/MyGame.exe --hud  # auto-picks a backend; --backend to override
neutron run game.exe --dry-run               # print the env and command instead of running

# Wine tools inside a prefix, and stopping everything in it
neutron wine -- winecfg
neutron kill                                  # or --all; uses the prefix's own wineserver
```

State lives in `~/Library/Application Support/Neutron` (override with `NEUTRON_HOME`).
Every `neutron run` also writes a log to `logs/<prefix>/` there (the newest 20 are kept;
`--no-log` to skip), starting with the exact environment and command, which is handy for
bug reports.
### In-game video

Games that play video through Media Foundation (most Unity and many Unreal games) need
Wine's GStreamer bridge, which needs GStreamer itself. Install the official runtime package
and register your Wine with `--gstreamer /Library/Frameworks/GStreamer.framework`; Neutron
then points Wine at its libraries and plugins, and refreshes GStreamer's plugin list under
`runtimes/gstreamer/` with the framework's `gst-inspect-1.0` before each launch (a couple of
seconds the first time; inside Wine it would take over a minute). Without it those games show a black screen or skip the video, and
`neutron doctor` warns about it. To add it to a Wine you've already registered, run
`neutron runtime set-gstreamer <version> /Library/Frameworks/GStreamer.framework`.

Steam games usually need a `steam_appid.txt` containing the game's app ID next to the
`.exe` when Steam isn't running.

## How backends are applied

Neutron never modifies the Wine builds you register. For DXMT or D3DMetal it launches a
*composed runtime*: an APFS clone of your Wine build with the backend's DLLs overlaid,
built once per Wine + backend pair under `runtimes/composed/`. The clone shares disk blocks
with the original, so it costs almost no space and takes about a second. The first launch
with a backend also runs `wineboot -u` so the prefix knows about the backend's DLLs.
Switching backends is just a different launch.

Auto-detection recognises Unity, Unreal and Godot games (following Unreal's stub launchers
to the real `*-Shipping.exe`). Godot 4 games are told to use Vulkan, which runs through
Wine's MoltenVK, so they need no Direct3D layer. Games that ship the D3D12 Agility SDK (Unity 6, Unreal 5) get
`d3dmetal`, falling back to `dxmt` if you haven't registered GPTK. Other engine games get
`dxmt` (Unreal is told to use D3D11 with `-dx11`; Unity falls back to D3D11 by itself). Everything else is
decided by the PE import tables of the `.exe` and the DLLs beside it: D3D12 → `d3dmetal`
(falling back to `dxmt` when the game imports D3D11 too), D3D10/11 → `dxmt`, older APIs → `wined3d`. `neutron detect game.exe` shows the reasoning.

## Roadmap

Phase 0 (hardware spike) → 1 (CLI, scaffolded) → 2 (compatibility database) → 3 (Steam)
→ 4 (SwiftUI app) → 5 (signing, downloads, smoke tests). Full plan, status and decisions:
[PROJECT-OUTLINE.md](PROJECT-OUTLINE.md). Spike checklist: [docs/phase0-spike.md](docs/phase0-spike.md).

## Known limits

- Kernel-level anti-cheat games won't run.
- Rosetta 2 is being phased out after macOS 27, apart from a subset kept for older games.
  We'll follow Apple's plans closely.
- D3DMetal can't be redistributed, so Neutron never bundles it.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). In short, fix bugs upstream where they belong.

## License

MIT. Wine, DXMT and the Game Porting Toolkit keep their own licenses;
the patches in `tools/wine-dxmt/` modify Wine and are LGPL-2.1-or-later like Wine.
