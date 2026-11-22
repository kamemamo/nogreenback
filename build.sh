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
VERSION=2.3.17
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
  # ATEM スイッチャーを USB でも操作するための SDK の窓口 (C++)
  objs=()
  for src in Sources/ATEMSDK/*.cpp; do
    obj="$VENDOR/obj/$(basename $src .cpp)-$arch.o"
    clang++ -std=c++17 -O2 -target $arch-apple-macos$MIN_OS -c "$src" -o "$obj"
    objs+="$obj"
  done
  swiftc -O -swift-version 5 \
    -F "$FW_BUILD" -framework Syphon \
    -import-objc-header Sources/ATEMSDK/ATEMBridge.h ${objs[@]} -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -target $arch-apple-macos$MIN_OS \
    Sources/*.swift -o "$VENDOR/obj/NoGreenBack-$arch"
  bins+="$VENDOR/obj/NoGreenBack-$arch"
done
lipo -create ${bins[@]} -output "$APP/Contents/MacOS/NoGreenBack"

cp -R "$FW_BUILD/Syphon.framework" "$APP/Contents/Frameworks/"
# アイコン (Icons/AppIcon.svg を変えたら: swiftc Tools/render-icon.swift -o vendor/render-icon && vendor/render-icon Icons/AppIcon.svg Icons/AppIcon.icns)
cp Icons/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# ライセンス (Syphon の BSD ライセンスは、バイナリで配るときに著作権表示を同梱するよう求めている)
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# 画面の文字の英語の訳 (日本語はソースの文をそのまま使う)
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NoGreenBack</string>
  <key>CFBundleDevelopmentRegion</key><string>ja</string>
  <key>CFBundleLocalizations</key><array><string>ja</string><string>en</string></array>
  <key>CFBundleIdentifier</key><string>local.nogreenback</string>
  <key>CFBundleExecutable</key><string>NoGreenBack</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>人物を切り抜いて Syphon で送出するためにカメラを使用します。</string>
  <key>NSMicrophoneUsageDescription</key><string>画面録画にマイクの音声を入れたり、字幕を付けたりするために使用します。</string>
  <key>NSLocalNetworkUsageDescription</key><string>ATEM スイッチャーの入力を切り替えるために、同じネットワークの機器と通信します。</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>話した言葉を字幕にするために使用します。認識は Mac の中で行います。</string>
</dict></plist>
PLIST

# 署名
# Developer ID の証明書がキーチェーンにあれば、それで署名する (Hardened Runtime 付き。公証を受けられる)。
# なければアドホック署名 (他の Mac では初回起動時に許可が必要)。
# 使う証明書を決めたいときは SIGN_ID="Developer ID Application: …" ./build.sh
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)}"
if [[ -n "$SIGN_ID" ]]; then
  echo "==> Developer ID で署名"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/Frameworks/Syphon.framework"
  codesign --force --options runtime --timestamp --entitlements NoGreenBack.entitlements --sign "$SIGN_ID" "$APP"
else
  codesign --force --sign - "$APP/Contents/Frameworks/Syphon.framework"
  # アドホック署名の既定の条件は「ビルドの中身 (cdhash) が同じこと」なので、ビルドし直すたびに
  # macOS からは別のアプリに見え、画面収録などの許可が外れてしまう。
  # 条件を「バンドル ID が local.nogreenback であること」にして、ビルドし直しても許可を引き継ぐ
  codesign --force --sign - -r='designated => identifier "local.nogreenback"' "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "==> 完成: $PWD/$APP  ($(lipo -archs "$APP/Contents/MacOS/NoGreenBack"))"

# 3) 配布用 zip
# Developer ID で署名していて、公証の設定 (xcrun notarytool store-credentials NoGreenBack) があれば、
# Apple の公証を受けてから zip にする (ダウンロードした人の Mac で警告が出なくなる)
NOTARY_PROFILE="${NOTARY_PROFILE:-NoGreenBack}"
if [[ "${1:-}" == "--zip" ]]; then
  mkdir -p dist
  rm -f dist/NoGreenBack.zip
  if [[ -n "$SIGN_ID" ]] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "==> Apple の公証を受けています (数分かかります)"
    ditto -c -k --sequesterRsrc --keepParent "$APP" dist/notarize.zip
    xcrun notarytool submit dist/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f dist/notarize.zip
    # 公証の結果をアプリに添付する (ネットにつながっていない Mac でも警告が出ないように)
    xcrun stapler staple "$APP"
    spctl -a -vv "$APP"
  elif [[ -n "$SIGN_ID" ]]; then
    echo "==> 公証の設定 ($NOTARY_PROFILE) がないので、公証は受けずに zip にします"
  fi
  ditto -c -k --sequesterRsrc --keepParent "$APP" dist/NoGreenBack.zip
  echo "==> 配布用: $PWD/dist/NoGreenBack.zip"
fi
