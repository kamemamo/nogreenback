# NoGreenBack Windows 版（作っている途中）

Mac 版と同じ動きを Windows で再現するためのフォルダです。何をどう作るかは [docs/SPEC.md](../docs/SPEC.md) にまとめていて、「17. Windows 版で決めたこと」で次のように決めています。

- C#（.NET 10）＋ WPF。映像は Direct3D 11 で描く
- 人物の切り抜きは ONNX Runtime ＋ DirectML
- 字幕の認識は Whisper（この PC の中だけ）
- ショートカットは Ctrl＋Alt＋Shift＋キー、描くキーの既定は Ctrl
- 動かすのは Windows 11

## ビルド

必要なもの: Windows 11、.NET 10 SDK

```bash
cd windows
dotnet build
```

```bash
windows/NoGreenBack/bin/Debug/net10.0-windows10.0.22621.0/NoGreenBack.exe
```

英語の表示を確かめるときは、環境変数 `NOGREENBACK_LANG=en` を付けて起動します。

## できていること

- 操作ウィンドウの骨組み（上部のボタン、プレビューの場所、サイドバー）
- 設定の保存（`%APPDATA%\NoGreenBack\settings.json`。キーの名前は Mac 版と同じ）
- 表示の言語（英語の訳は Mac 版の `Resources/en.lproj/Localizable.strings` をそのまま読み、Windows だけの文は `NoGreenBack/Resources/en.strings` に書く）
- ほかのアプリが前面でも効くショートカットの登録と、ショートカットの一覧（Ctrl+/）
- ボタンどうしの決まり（ペン固定をオンにすると手書きもオン、全画面を外すとペン固定も外れる、など）
- カメラの取り込み（`Video/CameraCapture.cs`）: 形式の選び方、遅れたコマを捨てる、3 秒コマがなければ開き直す、あとからつないだカメラを自動で開く
- Direct3D 11 での合成とプレビュー（`Video/Gpu.cs`、`Video/Pipeline.cs`）: 人物の位置・大きさ・左右反転・「人物」のオン・オフ、透明な部分の市松模様、カメラがないときの 25 回/秒の合成、フレームレートの表示
  - 人物の切り抜きはまだないので、カメラの映像をそのまま「人物」として置いています
  - 「映像の比率」の「出す画面に合わせる」は、画面の一覧を作ってから効くようにします（今はカメラと同じ比率）

動きを確かめるためのログは `%LOCALAPPDATA%\NoGreenBack\log.txt`（カメラの形式など）、思わぬエラーで止まったときは `crash.log` に残ります。

## これから作るもの

1. 人物の切り抜き（モデルを 2〜3 個試して決める）
2. 画面の一覧と、全画面出力・ワイプ
3. 手書き・ホワイトボード・キーボード・指し棒
4. Spout での送出
5. 画面録画と字幕
6. 外部の音声と ATEM
