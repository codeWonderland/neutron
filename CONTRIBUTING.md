# Contributing

## Upstream first

Neutron is a thin layer. When a game breaks inside Wine, DXMT or D3DMetal, the fix belongs
in that project:

- Wine bugs: https://bugs.winehq.org
- DXMT bugs: https://github.com/3Shain/dxmt/issues
- D3DMetal bugs: Apple's Feedback Assistant

Neutron changes should cover choosing, configuring and launching those tools. A workaround
for a specific game goes in the compatibility database (Phase 2), not in code.

## Development

Requires macOS 14+ on Apple Silicon and Xcode 16 or the Swift 6 toolchain.

```sh
swift build
swift test
NEUTRON_HOME=/tmp/neutron-dev swift run neutron prefix list   # keep dev state separate
```

Keep `NeutronCore` free of UI and CLI code so the CLI and the future SwiftUI app can share it.
Put launch logic in pure functions (see `LaunchPlan`) so it can be tested without running Wine.

## Licensing

Never commit or redistribute Game Porting Toolkit files. Users supply their own copy.
