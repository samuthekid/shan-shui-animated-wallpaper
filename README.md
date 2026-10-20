# Shan Shui Animated Wallpaper

An endless Chinese ink landscape that drifts slowly across your Mac desktop. Mountains, mist, water and trees, a new scene each time. A tiny menu-bar app, native, with very low CPU use.

**→ [samuapps.dev/shan-shui](https://samuapps.dev/shan-shui/)**

## Download

Coming soon to the Mac App Store. Until then, build it from source (below).

Requires macOS 14 or later.

## Use

1. Open the app. A 山水 item appears in the menu bar.
2. Use it to Pause, change Speed and Density, export the current frame as a PNG, or quit.
3. The landscape runs on every connected display. It pauses by itself when the screen is locked or the Mac sleeps.

To start it at login: System Settings → General → Login Items, then add the app.

## Privacy

No data is collected and the app uses no network. See the [privacy policy](https://samuapps.dev/shan-shui/privacy).

## Build from source

```bash
git clone --recurse-submodules https://github.com/samuthekid/shan-shui-animated-wallpaper
cd shan-shui-animated-wallpaper
bash build.sh
open build/ShanShui.app
```

Requires the Xcode command line tools (`xcode-select --install`). For the Mac App Store release: `xcodegen generate`, open `ShanShui.xcodeproj`, then Product → Archive.

Test flags (on `build/ShanShui.app/Contents/MacOS/ShanShui`): `--window [--windows N]`, `--seconds N`, `--debug DIR`, `--sweep`.

## Credits

The landscape generator is [shan-shui-inf](https://github.com/LingDong-/shan-shui-inf) by LingDong- (MIT, [license](vendor/shan-shui-inf/LICENSE)), in `vendor/`.
