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
- 画面の一覧（`Displays.cs`）: 名前はモニターの名前（内蔵の画面は「内蔵ディスプレイ」）、表示する画面・出す画面の既定、画面をつないだり外したりしたときの作り直し、「映像の比率」の「出す画面に合わせる」
- 全画面出力（`Video/OutputWindows.cs`）: 出す画面全体を覆う枠のないウィンドウ、Esc で閉じる、出していた画面が外れたら閉じる
- ワイプ（`Video/OutputWindows.cs`）: 透明でクリックを後ろへ通す最前面のウィンドウ（DirectComposition）、1 秒ごとに最前面を取り直す、全画面出力が同じ画面にある間は隠す
  - 画面が 1 台の PC でしか確かめていません。2 台目の画面に出す・画面を抜き差しする・PowerPoint のスライドショーより手前に出るかは、まだ確かめていません
- 手書き（`Overlays/Annotations.cs`）: 画面ごとの透明なウィンドウ、描くキー（Ctrl / Alt / Ctrl+Alt）を押している間とペン固定の間だけ描ける、2 回押し・右クリック・消去で全部消す、線を消す（3 秒・10 秒）、全画面出力を出している間はその画面だけで描け、その画面の線は合成した映像にも入る
- ホワイトボード・キーボード・指し棒（`Overlays/`）: 板は映像（背景の上・人物の後ろ）と「表示する画面」に出す（全画面出力の間は映像だけ）。キーボードは映像と「表示する画面」に出す。指し棒はマウスのある画面に出し、全画面出力の画面では映像の中に描く。指し棒の間はカーソルを隠す
  - 重なり順は、奥からホワイトボード・ワイプ・キーボード・全画面出力・手書き・指し棒。1 秒ごとに並べ直す
  - 描くキーの 2 回押しで全部消す動きと、PowerToys の「マウスを見つける」（Ctrl の 2 回押し）とのぶつかりは、まだ実際のキーで確かめていません
- 背景映像（`Video/BackgroundSource.cs`）: 「なし（透明）」「画面: ○○」「キャプチャー機器やカメラ」。映像の一番奥に、切らずに全部入るように縮めて真ん中に置く（余りは黒）
  - 機器は 1920x1080 で開き、3 秒コマがなければ開き直す。カメラと同じ機器を選んだときは、開き直さずにカメラのコマ（切り抜く前）を使う（同じ機器を 2 つ開くと取り合って交互に止まるため）
  - 画面は Windows.Graphics.Capture で GPU のまま取り込む（長辺 1920 には縮めない）。画面を背景にしている間だけ、このアプリのウィンドウ（手書きとホワイトボード以外）を `WDA_EXCLUDEFROMCAPTURE` で取り込みから外す（外したままにすると、ほかのアプリの画面共有からもワイプなどが消えるため）
  - 板を出している画面を背景にしているときは、映像に板を重ねない（二重にしない）
- Spout での送出（`Video/SpoutSender.cs`）: 送り手の名前は `NoGreenBack`。Spout2 の送り手の決まりに合わせて C# だけで送る。背景があれば合成と同じもの、なければ人物を元の大きさのまま（板・キーボード・手書き・指し棒は入れない）
  - 「上下反転」の既定は、Windows ではオフ（Direct3D のテクスチャは上から下に並ぶため。Mac 版の既定はオン）
  - 受け取る側から確かめるときは `dotnet run --project windows/Tools/SpoutCheck` を使う（大きさ・上下の向き・αの形式を数字で出す）。OBS などの実際の受け取るアプリでは、まだ確かめていません
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

1. 画面録画と字幕
2. 外部の音声と ATEM
