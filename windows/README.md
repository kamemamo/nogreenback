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
  - 「映像の比率」の「出す画面に合わせる」は、画面の一覧を作ってから効くようにします（今はカメラと同じ比率）
- 人物の切り抜き（`Video/Segmenter.cs`）: 明るさ安定化、ONNX Runtime（DirectML、使えなければ CPU）での人物マスク、品質の 3 段階、マスクの後処理（ちらつき抑制・消失の保持・境界の締まり・境界ぼかし）

動きを確かめるためのログは `%LOCALAPPDATA%\NoGreenBack\log.txt`（カメラの形式など）、思わぬエラーで止まったときは `crash.log` に残ります。

## 人物の切り抜きのモデル

モデルは git に入れていません。取り出したら、まず次を 1 回実行します（Hugging Face から約 26 MB。どちらも Apache-2.0）。

```bash
powershell -ExecutionPolicy Bypass -File windows/models/download.ps1
```

| 品質 | モデル | 入力 |
|---|---|---|
| Fast | MediaPipe Selfie Segmentation (landscape) | 256x144 |
| Balanced（既定） | MODNet | 512x288 |
| Accurate | MODNet | 672x384 |

GPU（DirectML）が使えない PC では、どの品質でも Fast を CPU で動かします。どれで動いているかは `log.txt` の「切り抜き:」の行でわかります。

### 比べたときの記録

2026-11-19、RTX 4080 Laptop / i9-14900HX、カメラ 1920x1080・30fps、Release ビルドで、1 コマの切り抜きにかかった時間（縮小 + 推論 + 後処理）:

| モデル | 入力 | GPU（DirectML） | CPU | 推論だけ GPU / CPU（`Tools/SegBench`） |
|---|---|---|---|---|
| MediaPipe Selfie Segmentation (landscape) | 256x144 | 5.7 ms | 2.8 ms | 1.6 / 1.2 ms |
| PP-HumanSeg（PaddleHub 版） | 192x192 | 6.0 ms | 4.6 ms | 1.0 / 2.8 ms |
| MODNet | 512x288 | 13.0 ms | 43.4 ms（22 fps に落ちる） | 5.5 / 36.8 ms |
| MODNet | 672x384 | 16.0 ms | 74.1 ms（12 fps） | 7.6 / 66.3 ms |
| MODNet | 896x512 | 18.7 ms | 138.3 ms（8 fps） | 11.7 / 124.8 ms |

- 縁の質は、実際に人を映して見比べ、どれも使える出来でした。
- GPU ならどのモデルも 30 fps に収まります。CPU では MediaPipe と PP-HumanSeg だけが間に合います。PP-HumanSeg は正方形の入力で、MediaPipe より CPU で遅いので使いません。
- アプリの中の GPU の推論は、ベンチマーク（続けて回す）の 2〜3 倍かかっています。コマの合間に GPU のクロックが下がるためと考えられます。
- MODNet の fp16 版は、DirectML でも速くなりませんでした（512x288 で 5.2 ms、672x384 で 6.6 ms）。
- 内蔵 GPU だけの PC での速さは、まだ測っていません。ほかの PC で測るときは `dotnet run -c Release --project windows/Tools/SegBench` を使います。

## これから作るもの

1. 画面の一覧と、全画面出力・ワイプ
2. 手書き・ホワイトボード・キーボード・指し棒
3. Spout での送出
4. 画面録画と字幕
5. 外部の音声と ATEM
