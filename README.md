# ShanShui wallpaper
Animated macOS desktop wallpaper: a procedural Chinese landscape with a slow, endless pan. No web view.

- Needs: macOS 14+, the Xcode Command Line Tools, and the upstream code in `vendor/` (a pinned git submodule). Clone with `git clone --recurse-submodules`, or run `git submodule update --init` after a plain clone.
- Build: `bash build.sh`. Run: `open build/ShanShui.app`.
- Settings (Speed, Density) and Quit: the 山水 item in the menu bar.
- Start at login: System Settings > General > Login Items, then add `build/ShanShui.app`.
- Test flags (on `build/ShanShui.app/Contents/MacOS/ShanShui`): `--window [--windows N]`, `--seconds N`, `--debug DIR`, `--sweep`. Each screen shows its own landscape.

Landscape code: [shan-shui-inf](https://github.com/LingDong-/shan-shui-inf) by LingDong- (MIT, [license](vendor/shan-shui-inf/LICENSE)), in `vendor/`.
