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

アイコン（`NoGreenBack/Resources/AppIcon.ico`）は、Mac 版と同じ `Icons/AppIcon.png` から作っています。Mac のアイコンにある周りの透明な余白を詰め、16〜256 px の 9 つの大きさを入れています。`Icons/AppIcon.png` を変えたら、次で作り直します。

```bash
dotnet run --project windows/Tools/MakeIcon
```

配布用の zip（.NET を同梱した自己完結型・署名なし）は、次で `windows/dist/NoGreenBack-Windows-<版>.zip` にできます。人物の切り抜きのモデルを同梱するので、先に `windows/models/download.ps1` を実行しておきます。zip に添えるライセンスの説明は `windows/Tools/release-notices.txt` です。

```bash
powershell -ExecutionPolicy Bypass -File windows/Tools/make-release.ps1
```

### Microsoft Store 用の MSIX（準備中）

Store に出すための MSIX（`windows/dist/NoGreenBack-Windows-<版>.msix`、署名なし）は、次で作ります。中身は上の zip と同じもの（モデル・ライセンスを含む）で、`windows/Packaging/AppxManifest.xml`（設定）と `windows/Packaging/Images`（タイルの画像）を足して、Windows SDK の `makeappx` でまとめます。Windows SDK を入れておきます。

```bash
powershell -ExecutionPolicy Bypass -File windows/Tools/make-msix.ps1
```

- **この PC で試す:** 「設定 → システム → 開発者向け」で開発者モードをオンにして、`-Register` を付けて実行します。署名なしのまま入り、スタートメニューの NoGreenBack から起動できます（`windows/dist/msix` を消すと起動できなくなります）。
- **Store に出す:** Partner Center でアプリ名を予約し、「製品の ID」に出る 3 つの値を `-Name`・`-Publisher`・`-PublisherDisplayName` で渡して作り、できた .msix を上げます。署名は Store が付けます。
- タイルの画像は `Icons/AppIcon.png` から `MakeIcon` で .ico と一緒に作ります。

MSIX で動かすと、次の点が zip 版と変わります。実機ではまだ確かめていません。

- **カメラ・マイク:** 設定に書いてあるので使えます。Windows の「プライバシーとセキュリティ」に NoGreenBack が 1 つのアプリとして並び、初めて使うときに許可を聞かれます。
- **取り込み中の黄色い枠:** 枠を消すには、設定に `graphicsCaptureWithoutBorder` を書き、使う人の同意（`GraphicsCaptureAccess.RequestAccessAsync`）を取る必要があります。コードがまだ同意を取っていないので、今の MSIX 版では枠が出ます。
- **設定・ログ・字幕のモデル:** `%APPDATA%` と `%LOCALAPPDATA%` への書き込みは、アプリ専用の場所に振り替えられます。zip 版の設定は引き継がれず、アンインストールすると消えます。
- **指し棒の間のカーソル隠し**（拡大鏡のしくみ）: zip 版と同じに動く見込みですが、確かめていません。

## できていること

- 操作ウィンドウの骨組み（上部のボタン、プレビューの場所、サイドバー）
- 設定の保存（`%APPDATA%\NoGreenBack\settings.json`。キーの名前は Mac 版と同じ）
- 表示の言語（英語の訳は Mac 版の `Resources/en.lproj/Localizable.strings` をそのまま読み、Windows だけの文は `NoGreenBack/Resources/en.strings` に書く）
- ほかのアプリが前面でも効くショートカットの登録と、ショートカットの一覧（Ctrl+/）。修飾キーは一覧の「組み合わせ」で Ctrl+Alt+Shift（既定）か Ctrl+Alt+Win を選ぶ
- 二重起動を防ぐ（2 つ目は、先に動いている方を前に出して終わる）
- ボタンどうしの決まり（ペン固定をオンにすると手書きもオン、全画面を外すとペン固定も外れる、など）
- カメラの取り込み（`Video/CameraCapture.cs`）: 形式の選び方、遅れたコマを捨てる、3 秒コマがなければ開き直す、あとからつないだカメラを自動で開く
- Direct3D 11 での合成とプレビュー（`Video/Gpu.cs`、`Video/Pipeline.cs`）: 人物の位置・大きさ・左右反転・「人物」のオン・オフ、透明な部分の市松模様、カメラがないときの 25 回/秒の合成、フレームレートの表示
- 画面の一覧（`Displays.cs`）: 名前はモニターの名前（内蔵の画面は「内蔵ディスプレイ」）、表示する画面・出す画面の既定、画面をつないだり外したりしたときの作り直し、「映像の比率」の「出す画面に合わせる」
- 全画面出力（`Video/OutputWindows.cs`）: 出す画面全体を覆う枠のないウィンドウ、Esc で閉じる、出していた画面が外れたら閉じる
- ワイプ（`Video/OutputWindows.cs`）: 透明でクリックを後ろへ通す最前面のウィンドウ（DirectComposition）、1 秒ごとに最前面を取り直す、全画面出力が同じ画面にある間は隠す
  - 画面が 1 台の PC でしか確かめていません。2 台目の画面に出す・画面を抜き差しする・PowerPoint のスライドショーより手前に出るかは、まだ確かめていません
- 手書き（`Overlays/Annotations.cs`）: 画面ごとの透明なウィンドウ、描くキー（Ctrl / Alt / Ctrl+Alt）を押している間とペン固定の間だけ描ける、2 回押し・右クリック・消去で全部消す、線を消す（3 秒・10 秒）、全画面出力を出している間はその画面だけで描け、その画面の線は合成した映像にも入る
- ホワイトボード・キーボード・指し棒（`Overlays/`）: 板は映像（背景の上・人物の後ろ）と「表示する画面」に出す（全画面出力の間は映像だけ）。キーボードは映像と「表示する画面」に出す。指し棒はマウスのある画面に出し、全画面出力の画面では映像の中にも描く（プレビューと Spout のため）。指し棒の間はカーソルを隠す
  - デスクトップの指し棒（`Overlays/PointerSurface.cs`）は、すべての画面を覆う透明なウィンドウに DirectComposition で置き、専用のスレッドで画面の合成の 1 回ごとにマウスの位置を読んで動かす。全画面出力の上にも、このウィンドウを重ねる（映像の中の指し棒はカメラのコマごとにしか動かないため、全画面出力には映像の中の指し棒を入れない）
  - マウスを一定の速さで動かして測ったところ、画面の合成ごとに動き、動く間隔の最大はデスクトップで 9.9 ms（合成は 1 秒に約 150 回）、全画面出力の上で 4.5 ms（240 回）だった（それまでは 60 回/秒のタイマーで、16〜31 ms のばらばらな間隔だった）
  - 重なり順は、奥からホワイトボード・ワイプ・キーボード・全画面出力・手書き・指し棒。1 秒ごとに並べ直す
  - 描くキーの 2 回押しで全部消す動きと、PowerToys の「マウスを見つける」（Ctrl の 2 回押し）とのぶつかりは、まだ実際のキーで確かめていません
  - キーボードを出している間は、実際に押したキーを光らせ、「Ctrl + Shift + S」のような組み合わせをキーボードの上に出す（`Overlays/KeyPressWatcher.cs`。低レベルのキーボードフックで見るだけ。許可は要らない）。**パスワードの欄に打っても隠れないので、パスワードを打つときはキーボードを消してください。** Mac でビルドが通ることまでしか確かめていません
- 背景映像（`Video/BackgroundSource.cs`）: 「なし（透明）」「画面: ○○」「キャプチャー機器やカメラ」。映像の一番奥に、切らずに全部入るように縮めて真ん中に置く（余りは黒）
  - 機器は 1920x1080 で開き、3 秒コマがなければ開き直す。カメラと同じ機器を選んだときは、開き直さずにカメラのコマ（切り抜く前）を使う（同じ機器を 2 つ開くと取り合って交互に止まるため）
  - 画面は Windows.Graphics.Capture で GPU のまま取り込む（長辺 1920 には縮めない）。画面を背景にしている間だけ、このアプリのウィンドウ（手書きとホワイトボード以外）を `WDA_EXCLUDEFROMCAPTURE` で取り込みから外す（外したままにすると、ほかのアプリの画面共有からもワイプなどが消えるため）
  - 板を出している画面を背景にしているときは、映像に板を重ねない（二重にしない）
- Spout での送出（`Video/SpoutSender.cs`）: 送り手の名前は `NoGreenBack`。Spout2 の送り手の決まりに合わせて C# だけで送る。背景があれば合成と同じもの、なければ人物を元の大きさのまま（板・キーボード・手書き・指し棒は入れない）
  - 「上下反転」の既定は、Windows ではオフ（Direct3D のテクスチャは上から下に並ぶため。Mac 版の既定はオン）
  - 受け取る側から確かめるときは `dotnet run --project windows/Tools/SpoutCheck` を使う（大きさ・上下の向き・αの形式を数字で出す）。OBS などの実際の受け取るアプリでは、まだ確かめていません
- 画面録画（`Video/ScreenRecorder.cs`、`Recording/RecordingController.cs`）: 「録画する画面」を Windows.Graphics.Capture で取り込み、長辺を GPU で縮めて、Media Foundation のハードウェアエンコーダー（H.264 / HEVC）で書く。「ビデオ」フォルダに保存し、エクスプローラーで選んで見せる
  - 録画中は断片化した MP4（`○○.recording.mp4`、2 秒ごとにキーフレーム）に書き、止めたら再圧縮せずに通常の MP4 に詰め替える。録画中にアプリを強制終了しても、`.recording.mp4` はその直前まで再生できることを確かめた
  - 録画停止のパネル（録画している画面の右上、ドラッグで動かせる）。操作ウィンドウと同じ画面を録画するときは、操作ウィンドウを最小化して、止めたら戻す
  - 録画に映さないもの（操作ウィンドウ・録画停止のパネル・全画面出力の画面の手書き）は `WDA_EXCLUDEFROMCAPTURE` で外す。背景にしている画面と同じ画面を録画するときは、背景のために外したワイプなども録画に映らない（この指定は取り込みごとに分けられないため）
  - 録画は合成とは別の Direct3D のデバイスで行う（エンコーダーと合成が同じデバイスの状態を取り合わないように）
  - 音声は AAC・48 kHz・モノラル。Windows の AAC エンコーダーは 96 / 128 / 160 / 192 kbps だけなので、64 kbps は 96、256 kbps は 192 にする
- マイク（`Audio/MicInput.cs`）: 「なし」「システムの設定に合わせる」とマイクの一覧、メーター。AudioGraph で 48 kHz・モノラル・32 bit 浮動小数にそろえ、録画も同じ入力を使う
- 外部の音声（`Audio/ExternalAudio.cs`）: 入力を選ぶと取り込み続け、選んだスピーカーにそのまま出す（音量はスピーカーと録画の両方に効く）。録画では、マイクの音に「外部 × 下げる倍率 × 音量」を足し、話している間は外部の音を下げる（-36 dBFS を超えたら 0.05 秒で下げ、話し終えて 0.6 秒たったら 0.5 秒で戻す）。マイクが「なし」なら外部の音だけを録る。外部の機器とマイクが同じなら混ぜない
  - 外部の音だけを録る・スピーカーに出すところまで確かめた。マイクと混ぜる・声で下げるは、入力の機器が 2 つ要るので、まだ確かめていません
- ATEM スイッチャー（`Atem/`）: USB で ATEM（Blackmagic のメーカー番号 0x1EDB で、名前に「ATEM」）がつながったら、ATEM Software Control の SDK（COM）で自動でつなぎ、上部に入力ボタンと「ミックス」を出す。押した入力を本番に出し、ATEM 本体で切り替えてもボタンが追従する。SDK がなければ、サイドバーに入れ方を出す
  - SDK の COM の宣言は、SDK の `BMDSwitcherAPI.idl` のメソッドの順のとおりに C# で書いた（C++ の DLL は挟まない）。ATEM がつながっていないときに SDK を呼んで、決まりどおりの失敗（応答なし）が返ることまで確かめた。実際の ATEM での切り替えは、まだ確かめていません
- 字幕（`Speech/`）: Whisper（whisper.cpp を Whisper.net から使う）でこの PC の中だけで認識する。話している途中の文字、置き換え（上部の辞書のボタンの吹き出し）、映像の中・背景がないときの Spout・「表示する画面」の下への表示、録画の .srt と MP4 の中の字幕トラック（tx3g）
  - マイクの音を 16 kHz にし、音の大きさで話している区間を見つけ、話している間は約 1 秒ごとに区間を読み直して途中の文字を出し、0.7 秒黙ったら（または 20 秒続いたら）文を確定する
  - 無音や雑音のときに出がちな決まり文句（「ご視聴ありがとうございました」など）や、[音楽] などの音の説明は字幕にしない
  - AI での直しは初版では入れていない（吹き出しでは選べなくして、理由を出す）
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

## 字幕のモデル

初めて字幕をオンにしたときに、確かめてから Hugging Face（ggerganov/whisper.cpp、版を固定）から `%LOCALAPPDATA%\NoGreenBack\models` に取ってきます。大きさと SHA-256 を確かめます。

| PC | モデル | 大きさ |
|---|---|---|
| GPU（Vulkan）が使える | large-v3-turbo（q5_0） | 574 MB |
| GPU が使えない | small（q5_1） | 190 MB |

GPU が使えるかは、`vulkan-1.dll` を読み込めるかで決めます。どれで動いているかは `log.txt` の「字幕:」の行でわかります。

### 比べたときの記録

2026-11-19、RTX 4080 Laptop / i9-14900HX、Release ビルドで、Windows の音声合成（Microsoft Ayumi）で読み上げた文を 1 回認識するのにかかった時間（`Tools/WhisperBench`。準備の 1 回目は数えない）:

| モデル | 日本語 12.0 秒 | 日本語 5.5 秒 | 英語 10.6 秒 |
|---|---|---|---|
| large-v3-turbo（q5_0）・Vulkan | 645 ms | 528 ms | 525 ms |
| small（q5_1）・Vulkan | 429 ms | 314 ms | 310 ms |
| large-v3-turbo（q5_0）・CPU | 10,263 ms | 10,136 ms | 10,617 ms |
| small（q5_1）・CPU | 2,349 ms | 2,156 ms | 2,197 ms |

- どの組み合わせも、読み上げた文をほぼそのまま書き取りました（英語の features が feature になったくらい）。
- Whisper は 30 秒の単位で処理するので、音が短くても時間はあまり変わりません。CPU で large-v3-turbo は 1 回 10 秒かかり、字幕に使えないので、GPU がない PC では small にします。small は CPU でも 1 回 約 2.2 秒で、途中の文字は 3 秒ほどごとに変わります。
- GPU の 1 回目は準備に時間がかかるので、モデルを読み込んだら無音で 1 回読んでおきます。この準備は、その実行ファイルで初めて動かしたときだけ 10 秒ほどかかり（GPU のドライバーが準備したものを残すため）、2 回目からは読み込みと合わせて約 1 秒でした。
- アプリの認識の流れ（区間・途中の文字・確定）を、読み上げた音を実時間で流して確かめました（GPU）: 話し始めから約 1 秒で途中の文字が出て、約 1.4 秒ごとに変わり、話し終えてから約 0.9 秒で文が確定しました。1 回の認識は平均 373 ms でした。
- 実際のマイクで話しての確認と、内蔵 GPU だけの PC・GPU のない PC での速さは、まだ確かめていません。ほかの PC で測るときは `dotnet run -c Release --project windows/Tools/WhisperBench -- vulkan`（CPU は `-- cpu`）を使います。

## これから作るもの

SPEC.md に書いた機能は、ひととおり作りました。残っているのは、この PC で確かめられなかったところの確認です（2 台目の画面、PowerPoint のスライドショー、OBS などで Spout を受け取る、外部の音声をマイクと混ぜる、実際の ATEM）。
