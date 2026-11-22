# 開発の進め方（Mac 版と Windows 版）

NoGreenBack は、Mac 版と Windows 版を 1 つのリポジトリ（GitHub の `kamemamo/nogreenback`）で作っています。Mac 版は Mac で、Windows 版は Windows の機械で作り、どちらも Claude Code と一緒に進めます。

この文書は、ブランチの使い分け、ふだんの作業の流れ、リリースの手順をまとめたものです。Claude が守る約束は [CLAUDE.md](../CLAUDE.md)、アプリの動きは [SPEC.md](SPEC.md) にあります。

## 1. 全体の形

```
                 ┌──────────── プルリクエスト ────────────┐
                 │                                          ▼
 windows ────●───●────────────────────────────────►  main ──► リリース（タグ）
 （Windows 版の作業）                                  ▲
                                                       │ 早送り
 feature/… ──●───●──► develop ────────────────────────┘
 （Mac 版の作業）     （次に出す版をまとめる所）
```

| ブランチ | 役目 | 誰が動かすか |
|---|---|---|
| `main` | リリースする版。いつでも出せる状態にしておく | Mac 側・Windows 側の両方 |
| `develop` | 次に出す版をまとめる所。いつも `main` と同じか、少し先 | Mac 側（Windows の変更が入ったら追いつかせる） |
| `feature/…` | Mac 版の作業場所（今は `feature/smart-subtitles`） | Mac 側 |
| `windows` | Windows 版の作業場所 | Windows 側 |

大事な決まりが 3 つあります。

- **プッシュした履歴は書き換えません。** amend・rebase・force push はしません。間違えたときは、直すコミットを新しく足します。
- **`main` へは、早送り（Mac 版）かプルリクエスト（Windows 版）でだけ入れます。** `main` で直接作業しません。
- **コミット・プッシュ・マージ・リリースは、頼んだときだけ Claude が行います。**

## 2. Mac での作業の流れ

1. 作業の前に最新を取ってきます（Claude に「git pull」）。Windows 側の変更が `main` に入っていれば、作業ブランチを `main` に追いつかせてから始めます。
2. `feature/…` ブランチで直します。動きを変えたら、仕様書・英語の訳・README も一緒に直します（下の「4. 両方にかかわる変更」）。
3. `./build.sh` でビルドし、実機で試します。
4. 「コミットしてプッシュ」で、`feature/…` にコミットして GitHub に送ります。
5. 「マージしてプッシュ」で、`develop` → `main` の順に早送りでマージして、3 つともプッシュします。

```bash
git push origin feature/smart-subtitles:develop feature/smart-subtitles:main
```

**`main` が先に進んでいたとき**（Windows のプルリクエストが入った後など）は早送りできません。そのときは次のどちらかにします。

- まだコミットしていなければ、先に作業ブランチを `main` に追いつかせてからコミットする。
- もうプッシュしていれば、`main` を作業ブランチにマージするコミットを作る（rebase はしない）。

## 3. Windows での作業の流れ

1. 作業の前に `windows` ブランチを最新にします（`git pull`）。Mac 側の変更が `main` に入っていれば、`windows` を `main` に追いつかせてから始めます。
2. `windows` ブランチで直し、`windows` フォルダで `dotnet build` してから実機で試します。
3. コミットして `windows` を GitHub にプッシュします。
4. `windows` → `main` のプルリクエストを作り、マージします（コミットを残す「Create a merge commit」で）。
5. マージしたら、`develop` と `windows` を `main` に追いつかせます。

```bash
git push origin origin/main:refs/heads/develop origin/main:refs/heads/windows
```

**Mac で Windows 版を直すこともできます。** そのときは、Mac の作業を邪魔しないよう、`windows` ブランチを別のフォルダに取り出して（`git worktree add`）作業し、`dotnet build -p:EnableWindowsTargeting=true` でビルドが通ることを確かめます。Mac ではビルドまでしかできないので、動きは Windows の実機で確かめます。

## 4. 両方にかかわる変更

Mac 版と Windows 版は、同じ動きをすることを目標にしています。

- **動きを変えたら `docs/SPEC.md` を直します。** 片方だけ変えたときは、もう片方をどうするかも書いておきます（例: 「Mac 版は済み。Windows 版も合わせる」）。
- **両方の版を同じように直すときは、仕様書の文を両方のブランチでまったく同じにします。** 同じ文なら、あとでマージしてもぶつかりません。
- **仕様書をもう片方のブランチへ写すときは、ファイルごとコピーしません。** 相手のブランチにしかない変更を消してしまうので、直した行だけを書き換えます。
- **画面の文字**を足したり変えたりしたら、英語の訳も足します（`Resources/en.lproj/Localizable.strings`。Windows だけの文は `windows/NoGreenBack/Resources/en.strings`）。
- **使い方が変わったら** `README.md` と `README.en.md` の両方を直します。

## 5. 版の番号とリリース

版の番号は、Mac 版と Windows 版で別々に上げます（2026-11-21 に決め直し。それまではそろえていました）。

| | Mac 版 | Windows 版 |
|---|---|---|
| 版を書く所 | `build.sh` の `VERSION` | `windows/NoGreenBack/NoGreenBack.csproj` の `Version` |
| 配布用の zip を作る | Mac で `./build.sh --zip`（署名・公証） | Windows で `windows/models/download.ps1` のあと `windows/Tools/make-release.ps1` |
| タグ | `vX.Y.Z` | `windows-vX.Y.Z` |
| 題名 | NoGreenBack X.Y.Z | NoGreenBack for Windows X.Y.Z |
| GitHub の「最新」 | する | しない（正式なリリースだが「最新」は Mac 版のまま） |

### Mac 版を出す手順（「Mac X.Y.Z を出す」）

1. `build.sh` の `VERSION` を上げ、`Bump version to X.Y.Z` でコミットして、`develop`・`main` まで入れてプッシュします。
2. `./build.sh --zip` で zip を作ります（公証に数分かかります）。
3. zip を展開して、版の番号、公証の情報、Gatekeeper を通るかを確かめます。
4. タグを版上げのコミットそのもの（長いコミット番号）に付けてリリースします。公証を待つ間に Windows のプルリクエストで `main` が進むことがあるので、`main` ではなくコミット番号で指定します。

### Windows 版を出す手順

1. `NoGreenBack.csproj` の `Version` を上げ、`Bump Windows version to X.Y.Z` でコミットして、プルリクエストで `main` に入れます。
2. Windows の機械で zip を作り、タグ `windows-vX.Y.Z` でリリースします（「最新」にはしない）。

### リリースノート

日本語を先に書き、`---` で区切ってから英語を書きます。「変更点」と「インストール」の手順を毎回載せます。

### 出した後に直したくなったら

同じタグの zip を差し替えずに、版を上げて出し直します。タグが指すコミットと zip の中身がずれると、どのコードから作ったかわからなくなるためです。

## 6. コミットの書き方

- 1 行目は英語、本文は日本語（何をなぜ変えたか）。1 行目は GitHub のファイル一覧に出るので、英語の README を読む人にも読めるようにします。
- 版上げは `Bump version to 2.3.17`（Windows 版は `Bump Windows version to 2.3.16`）。
- Claude が作ったコミットは、本文の最後に Co-Authored-By の行を付けます。

## 7. Claude への頼み方

ふだん使っている言い方と、Claude がすることです。

| 言い方 | すること |
|---|---|
| git pull | 最新を取ってきて、どのブランチがどこにいるかを知らせる |
| コミットしてプッシュ | 今のブランチにコミットして GitHub に送る（Mac は `feature/…`、Windows は `windows`） |
| マージしてプッシュ | Mac 版を `develop` → `main` に早送りで入れて、3 つともプッシュ |
| PR を作る | `windows` → `main` のプルリクエストを作る |
| マージする | プルリクエストをマージし、`develop`・`windows`・Mac の作業ブランチを `main` に追いつかせる |
| 追いつかせる | 後ろにいるブランチを `main` まで早送りして、プッシュ |
| Mac X.Y.Z を出す | 上の「Mac 版を出す手順」を全部 |

Mac と Windows の両方で同時に作業しているときは、相手がプッシュする前に `main` を動かすと、相手のマージが早送りできなくなります。片方が作業中なら「今 Windows で作業しているのでちょっと待って」のように伝えてください。
