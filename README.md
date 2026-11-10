# NoGreenBack

Webカメラ映像から人物だけをリアルタイムで切り抜き（背景は透明）、Syphon で他のアプリ（OBS、Resolume、MadMapper など）へ送る macOS アプリです。

- 人物の切り抜き: Apple Vision の人物セグメンテーション（`VNGeneratePersonSegmentationRequest`）
- 合成: Core Image
- 送出: Metal テクスチャ → `SyphonMetalServer`（サーバー名 `NoGreenBack`）

## ビルド

必要なもの: Apple Silicon Mac、Xcode、Metal Toolchain（`xcodebuild -downloadComponent MetalToolchain`）

```bash
./build.sh
open NoGreenBack.app
```

`build.sh` は初回に Syphon-Framework を `vendor/` へ clone してビルドし、`NoGreenBack.app` を作ります。

## 他の Mac で使う

Apple Silicon / Intel 両対応、macOS 12 以降で動きます。他の Mac には Xcode は不要です。

1. この Mac で配布用 zip を作ります。

   ```bash
   ./build.sh --zip
   ```

2. `dist/NoGreenBack.zip` を AirDrop や USB などで他の Mac にコピーして展開し、`NoGreenBack.app` を「アプリケーション」フォルダに入れます。
3. 初回だけ起動の許可が必要です（Apple の公証を受けていないため）。次のどちらかで許可します。
   - ターミナルで次を実行してから、普通に開く

     ```bash
     xattr -dr com.apple.quarantine /Applications/NoGreenBack.app
     ```

   - 一度開こうとしてブロックされたあと、「システム設定 > プライバシーとセキュリティ」の下の方にある「このまま開く」を押す
4. 起動したらカメラへのアクセスを許可します。

## OBS での受信

ソースに「Syphon クライアント」を追加し、プロパティで `NoGreenBack` を選んで **「透過を許可」にチェック**を入れます（入れないと背景が黒になります）。

## 設定項目

| 項目 | 内容 |
|---|---|
| 品質 | Fast / Balanced / Accurate。Accurate ほど境界が正確で、負荷は高くなります |
| 左右反転 / 上下反転 | 映像の向き |
| ストレートα | オフ: プリマルチプライドα / オン: ストレートα。縁が黒や白に見えるときに切り替えます |
| ちらつき抑制 | 動きの少ない部分のマスクを時間方向に平滑化します |
| 消失の保持 | 人物判定が急に外れても、すぐ消さずにゆっくりフェードさせます（手を顔の前にかざしたときなど） |
| 境界の締まり | 半透明の縁を減らしてくっきりさせます |
| 境界ぼかし | マスクの境界をぼかします |

## 確認ツール

`Tools/syphon-check.swift` は Syphon サーバー一覧を表示し、NoGreenBack から 1 フレーム受信して PNG に保存します。

```bash
swiftc -F vendor/build -framework Syphon -Xlinker -rpath -Xlinker "$PWD/vendor/build" Tools/syphon-check.swift -o vendor/syphon-check
./vendor/syphon-check frame.png
```
