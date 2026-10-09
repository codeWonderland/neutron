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

## Quick start

```sh
swift build -c release
alias neutron="$PWD/.build/release/neutron"

# Register runtimes you've already downloaded
neutron runtime add wine ~/Downloads/wine-10.x
neutron runtime add dxmt ~/Downloads/dxmt-v0.x
neutron runtime add gptk "/Volumes/Evaluation environment for Windows games 2.1"

# Create a prefix and run something
neutron prefix create default
neutron detect ~/Games/MyGame/MyGame.exe     # shows graphics APIs and the backend it'd pick
neutron run ~/Games/MyGame/MyGame.exe --hud  # auto-picks a backend; --backend to override
neutron run game.exe --dry-run               # print the env and command instead of running

# Wine tools inside a prefix
neutron wine -- winecfg
```

State lives in `~/Library/Application Support/Neutron` (override with `NEUTRON_HOME`).

## How backends are applied

Neutron doesn't copy DLLs into prefixes or modify Wine builds. A backend's DLLs go on
`WINEDLLPATH` and are forced to builtin through `WINEDLLOVERRIDES`. Switching backends is
just a different launch, and one Wine build can serve every prefix.

Auto-detection reads the PE import tables of the `.exe` and the DLLs beside it:
D3D12 → `d3dmetal`, D3D10/11 → `dxmt`, everything else → `wined3d`.

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

MIT. Wine, DXMT and the Game Porting Toolkit keep their own licenses.
