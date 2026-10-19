#!/bin/bash
# ./build.sh        dev build: ad-hoc signature, debug flags kept.
# ./build.sh store  Mac App Store build: no debug code, sandbox, signed .pkg. Needs:
#   SIGN_ID       "Apple Distribution: NAME (TEAMID)"           (see: security find-identity -v -p codesigning)
#   INSTALLER_ID  "3rd Party Mac Developer Installer: NAME (TEAMID)" or the Mac Installer Distribution name
#   PROFILE       path to the .provisionprofile
# Put the real team ID in ShanShui.entitlements first (TEAMID_HERE).
set -euo pipefail
cd "$(dirname "$0")"

mode=${1:-dev}
[ "$mode" = dev ] || [ "$mode" = store ] || { echo "usage: $0 [store]" >&2; exit 2; }

if [ "$mode" = store ]; then
  : "${SIGN_ID:?set SIGN_ID}" "${INSTALLER_ID:?set INSTALLER_ID}" "${PROFILE:?set PROFILE}"
  [ -f "$PROFILE" ] || { echo "PROFILE not found: $PROFILE" >&2; exit 1; }
  [ -f Resources/ShanShui.icns ] || { echo "Resources/ShanShui.icns is missing (required for store)" >&2; exit 1; }
  [ -f Resources/background-4k.jpg ] || { echo "Resources/background-4k.jpg is missing (needed by Apply App Background)" >&2; exit 1; }
  ! grep -q TEAMID_HERE ShanShui.entitlements || { echo "Set the team ID in ShanShui.entitlements" >&2; exit 1; }
  flags=(-D STORE)
else
  flags=()
fi

# Build in a temporary folder. The old app stays if anything fails.
app=build/ShanShui.app
tmp=build/ShanShui.app.tmp
rm -rf "$tmp"
mkdir -p "$tmp/Contents/MacOS" "$tmp/Contents/Resources"

# Universal binary: one slice per architecture, joined with lipo.
slices=()
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O ${flags[@]+"${flags[@]}"} -target "$arch-apple-macos14.0" Sources/*.swift -o "$tmp/ShanShui-$arch"
  slices+=("$tmp/ShanShui-$arch")
done
lipo -create "${slices[@]}" -output "$tmp/Contents/MacOS/ShanShui"
rm "${slices[@]}"

cp vendor/shan-shui-inf/index.html Sources/generator.js PrivacyInfo.xcprivacy "$tmp/Contents/Resources/"
cp vendor/shan-shui-inf/LICENSE "$tmp/Contents/Resources/LICENSE-shan-shui-inf"
[ -f Resources/ShanShui.icns ] && cp Resources/ShanShui.icns "$tmp/Contents/Resources/"
[ -f Resources/background-4k.jpg ] && cp Resources/background-4k.jpg "$tmp/Contents/Resources/"  # still picture for Apply App Background; made with: ShanShui --still FILE.jpg (dev build, no window)

# Build-metadata keys (store only). Values come from the installed Xcode.
# Same key set and value format as Xcode-built Mac apps on this machine (ColorSlurp, AppCleaner).
# TODO verify: App Store Connect accepts exactly this set (only the validate/upload step proves it).
extra=""
if [ "$mode" = store ]; then
  xcode=$(xcodebuild -version | awk '/^Xcode/ {split($2, v, "."); printf "%02d%d%d", v[1], v[2], v[3]}')
  xcodebuild_build=$(xcodebuild -version | awk '/^Build version/ {print $3}')
  sdk=$(xcrun --show-sdk-version)
  sdkbuild=$(xcrun --show-sdk-build-version)
  # Checked against real Xcode-built apps: DTCompiler value, DTPlatformVersion = SDK version, DTPlatformBuild = DTSDKBuild.
  extra="
  <key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
  <key>DTPlatformBuild</key><string>$sdkbuild</string>
  <key>DTPlatformName</key><string>macosx</string>
  <key>DTPlatformVersion</key><string>$sdk</string>
  <key>DTSDKBuild</key><string>$sdkbuild</string>
  <key>DTSDKName</key><string>macosx$sdk</string>
  <key>DTXcode</key><string>$xcode</string>
  <key>DTXcodeBuild</key><string>$xcodebuild_build</string>
  <key>BuildMachineOSBuild</key><string>$(sw_vers -buildVersion)</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>"
fi

cat > "$tmp/Contents/Info.plist" <<EOT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.samuapps.shanshui</string>
  <key>CFBundleExecutable</key><string>ShanShui</string>
  <key>CFBundleName</key><string>Shan Shui Animated Wallpaper</string>
  <key>CFBundleDisplayName</key><string>Shan Shui Animated Wallpaper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>ShanShui</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Samuel</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>$extra
</dict>
</plist>
EOT
plutil -lint "$tmp/Contents/Info.plist" "$tmp/Contents/Resources/PrivacyInfo.xcprivacy"

if [ "$mode" = store ]; then
  # Profile path: Contents/embedded.provisionprofile (same place in Xcode-built apps). productbuild usage text: --component <app> <install-path>, for the Mac App Store.
  # Hardened runtime is not required for the store, but real store apps carry it. Harmless.
  cp "$PROFILE" "$tmp/Contents/embedded.provisionprofile"
  codesign --force --options runtime --timestamp --entitlements ShanShui.entitlements -s "$SIGN_ID" "$tmp"
  codesign --verify --deep --strict --verbose=2 "$tmp"
else
  codesign -s - --force "$tmp"
fi
rm -rf "$app"
mv "$tmp" "$app"
echo "Built $app ($mode)"

if [ "$mode" = store ]; then
  rm -f build/ShanShui.pkg
  productbuild --component "$app" /Applications --sign "$INSTALLER_ID" build/ShanShui.pkg
  pkgutil --check-signature build/ShanShui.pkg
  echo "Built build/ShanShui.pkg"
fi
