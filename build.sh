#!/bin/zsh
# NoGreenback をビルドして NoGreenback.app を作る
set -euo pipefail
cd "$(dirname "$0")"

VENDOR=vendor
FW_BUILD="$PWD/$VENDOR/build"
APP=NoGreenback.app

# 1) Syphon.framework (初回のみ)
if [[ ! -d "$VENDOR/Syphon-Framework" ]]; then
  git clone --depth 1 https://github.com/Syphon/Syphon-Framework.git "$VENDOR/Syphon-Framework"
fi
if [[ ! -f "$FW_BUILD/Syphon.framework/Versions/A/Syphon" ]]; then
  rm -rf "$FW_BUILD"
  echo "==> Syphon.framework をビルド"
  xcodebuild -project "$VENDOR/Syphon-Framework/Syphon.xcodeproj" -scheme Syphon \
    -configuration Release -destination 'generic/platform=macOS' \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CONFIGURATION_BUILD_DIR="$FW_BUILD" \
    CODE_SIGN_IDENTITY="-" build -quiet
fi

# 2) アプリ本体
echo "==> NoGreenback をビルド"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
swiftc -O -swift-version 5 \
  -F "$FW_BUILD" -framework Syphon \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -target arm64-apple-macos14.0 \
  Sources/*.swift -o "$APP/Contents/MacOS/NoGreenback"

cp -R "$FW_BUILD/Syphon.framework" "$APP/Contents/Frameworks/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NoGreenback</string>
  <key>CFBundleIdentifier</key><string>local.nogreenback</string>
  <key>CFBundleExecutable</key><string>NoGreenback</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>人物を切り抜いて Syphon で送出するためにカメラを使用します。</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "==> 完成: $PWD/$APP   (起動: open $APP)"
