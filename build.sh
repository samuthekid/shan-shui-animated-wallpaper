#!/bin/bash
# Dev build only: ad-hoc signature, debug flags kept. Run: ./build.sh, then open build/ShanShui.app
# The Mac App Store release is not built here. Use Xcode: xcodegen generate, open ShanShui.xcodeproj,
# Product > Archive, Distribute App (see project.yml).
set -euo pipefail
cd "$(dirname "$0")"

flags=()
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
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
EOT
plutil -lint "$tmp/Contents/Info.plist" "$tmp/Contents/Resources/PrivacyInfo.xcprivacy"

codesign -s - --force "$tmp"
rm -rf "$app"
mv "$tmp" "$app"
echo "Built $app (dev)"
