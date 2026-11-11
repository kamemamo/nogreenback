#!/bin/zsh
# NoGreenBack をビルドして NoGreenBack.app を作る
#   ./build.sh         … ビルドのみ
#   ./build.sh --zip   … ビルドして dist/NoGreenBack.zip (他の Mac 配布用) も作る
#
# Apple Silicon 専用、macOS 12 以降で動作 (Intel も必要なら ARCHS に x86_64 を足す)
set -euo pipefail
cd "$(dirname "$0")"

VENDOR=vendor
FW_BUILD="$PWD/$VENDOR/build"
APP=NoGreenBack.app
VERSION=1.3
MIN_OS=12.0
ARCHS=(arm64)

# 1) Syphon.framework (初回、またはユニバーサルでない場合のみ)
if [[ ! -d "$VENDOR/Syphon-Framework" ]]; then
  git clone --depth 1 https://github.com/Syphon/Syphon-Framework.git "$VENDOR/Syphon-Framework"
fi
FW_BIN="$FW_BUILD/Syphon.framework/Versions/A/Syphon"
if [[ ! -f "$FW_BIN" ]] || [[ "$(lipo -archs "$FW_BIN" | tr ' ' '\n' | sort | xargs)" != "$(print -l ${ARCHS[@]} | sort | xargs)" ]]; then
  rm -rf "$FW_BUILD"
  echo "==> Syphon.framework をビルド (${ARCHS[*]})"
  xcodebuild -project "$VENDOR/Syphon-Framework/Syphon.xcodeproj" -scheme Syphon \
    -configuration Release -destination 'generic/platform=macOS' \
    ARCHS="${ARCHS[*]}" ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=$MIN_OS \
    CONFIGURATION_BUILD_DIR="$FW_BUILD" CODE_SIGN_IDENTITY="-" build -quiet
fi

# 2) アプリ本体 (アーキテクチャごとにビルドして lipo で結合)
echo "==> NoGreenBack をビルド (${ARCHS[*]})"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources" "$VENDOR/obj"
bins=()
for arch in ${ARCHS[@]}; do
  swiftc -O -swift-version 5 \
    -F "$FW_BUILD" -framework Syphon \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -target $arch-apple-macos$MIN_OS \
    Sources/*.swift -o "$VENDOR/obj/NoGreenBack-$arch"
  bins+="$VENDOR/obj/NoGreenBack-$arch"
done
lipo -create ${bins[@]} -output "$APP/Contents/MacOS/NoGreenBack"

cp -R "$FW_BUILD/Syphon.framework" "$APP/Contents/Frameworks/"
# アイコン (Icons/AppIcon.svg を変えたら: swiftc Tools/render-icon.swift -o vendor/render-icon && vendor/render-icon Icons/AppIcon.svg Icons/AppIcon.icns)
cp Icons/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NoGreenBack</string>
  <key>CFBundleIdentifier</key><string>local.nogreenback</string>
  <key>CFBundleExecutable</key><string>NoGreenBack</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>人物を切り抜いて Syphon で送出するためにカメラを使用します。</string>
</dict></plist>
PLIST

# アドホック署名 (Developer ID 証明書がないため。他の Mac では初回起動時に許可が必要)
codesign --force --sign - "$APP/Contents/Frameworks/Syphon.framework"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "==> 完成: $PWD/$APP  ($(lipo -archs "$APP/Contents/MacOS/NoGreenBack"))"

# 3) 配布用 zip
if [[ "${1:-}" == "--zip" ]]; then
  mkdir -p dist
  rm -f dist/NoGreenBack.zip
  ditto -c -k --sequesterRsrc --keepParent "$APP" dist/NoGreenBack.zip
  echo "==> 配布用: $PWD/dist/NoGreenBack.zip"
fi
