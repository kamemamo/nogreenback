# NoGreenBack で作業するときの約束

Mac 版と Windows 版の両方で、Claude はこの約束に従って作業します。

## やり取り

- 返事は日本語で書きます。
- 説明は、専門用語をなるべく使わず、ふつうの言葉で書きます（README と同じ書き方）。

## リポジトリの中身

| 場所 | 中身 |
|---|---|
| `Sources/`、`build.sh` | Mac 版（Swift、Apple Silicon、macOS 12 以降） |
| `windows/` | Windows 版（C# .NET 10 ＋ WPF、Windows 11）。説明は `windows/README.md` |
| `docs/SPEC.md` | 両方の版が守る仕様書。Windows 版で決めたことは 17 章 |
| `README.md` / `README.en.md` | 使い方の説明（日本語と英語） |
| `Resources/en.lproj/Localizable.strings` | 画面の文字の英語訳。Windows 版もここを読む（Windows だけの文は `windows/NoGreenBack/Resources/en.strings`） |

## ビルド

- Mac 版: `./build.sh`。配布用は `./build.sh --zip`（Developer ID で署名・公証して `dist/NoGreenBack.zip` を作る）。
- Windows 版: `windows` フォルダで `dotnet build`。配布用は `windows/Tools/make-release.ps1`（先に `windows/models/download.ps1` でモデルを取ってくる）。

## 変更するとき

- 動きを変えたら、`docs/SPEC.md` も直します。Mac 版と Windows 版で同じ動きをさせたいので、片方だけ変えたときは、もう片方をどうするかを書いておきます。
- 画面の文字を足したり変えたりしたら、英語の訳も足します。
- 使い方が変わったら、`README.md` と `README.en.md` の両方を直します。

## コミット

- 1 行目は英語、本文は日本語で書きます（例: 1 行目 `Add a whiteboard behind drawings`、本文に何をなぜ変えたか）。
  - 1 行目を英語にするのは、GitHub のファイル一覧に出るのが 1 行目で、英語の README を読む人にも読めるようにするためです。
  - 版を上げるコミットは `Bump version to 2.3.12` のように書きます。
- Claude が作ったコミットは、本文の最後に Co-Authored-By の行を付けます。
- **プッシュした履歴は書き換えません**（amend・rebase・force push をしない）。英語の本文になっている過去のコミットも、そのままにします。

## ブランチ

- `main` … リリースする版。`develop` … 次に出す版をまとめる所。
- Mac 版は `feature/…` ブランチで作業し、`develop` → `main` の順に早送り（fast-forward）でマージして、3 つともプッシュします。
- Windows 版は `windows` ブランチで作業し、プルリクエストで `main` に入れます。入れたら `develop` も `main` に追いつかせます。
- コミットやプッシュ、マージ、リリースは、頼まれたときだけ行います。

## リリース

- **Mac 版**: `build.sh` の `VERSION` を上げてコミット・プッシュし、`./build.sh --zip` で作った zip を、タグ `vX.Y.Z`、題名「NoGreenBack X.Y.Z」でリリースします。GitHub の「最新」は Mac 版にします。
- **Windows 版**: `windows/NoGreenBack/NoGreenBack.csproj` の `Version` を上げ、`make-release.ps1` で作った zip を、タグ `windows-vX.Y.Z`、題名「NoGreenBack for Windows X.Y.Z」でリリースします。試作の間はプレリリースにして、「最新」にはしません。
- リリースノートは日本語を先に書き、`---` で区切ってから英語を書きます。インストールの手順も毎回載せます。

## 気をつけること

- 作業中に使っている NoGreenBack を勝手に終了・再起動しません。先に聞きます。
- カメラ・マイク・画面収録などの許可（プライバシーの設定）は変えません。
- パスワードや証明書の情報は入力しません。
- 人が映るので、カメラの画面写真は撮らずに、ログや画素の数字で確かめます。
