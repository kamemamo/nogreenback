# Microsoft Store 用の MSIX を作る (SPEC.md 17 章 7)
#   powershell -ExecutionPolicy Bypass -File windows\Tools\make-msix.ps1             # .msix を作る
#   powershell -ExecutionPolicy Bypass -File windows\Tools\make-msix.ps1 -Register   # 作って、この PC に入れて試す (開発者モードが要る)
# Store に出すときは、Partner Center の「製品の ID」に出る値を渡す:
#   ... make-msix.ps1 -Name "<Package/Identity/Name>" -Publisher "<Package/Identity/Publisher>" -PublisherDisplayName "<Package/Properties/PublisherDisplayName>"
# できるもの: windows\dist\NoGreenBack-Windows-<版>.msix (署名なし。Store に上げると Store が署名する)
# 中身は make-release.ps1 で作るもの (モデル・ライセンスを含む) をそのまま使う。先に windows\models\download.ps1 を実行しておく。
# 必要なもの: Windows SDK (makeappx.exe)

param(
    [string]$Name = 'NoGreenBack',
    [string]$Publisher = 'CN=NoGreenBack Dev',
    [string]$PublisherDisplayName = 'NoGreenBack',
    [switch]$Register,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$win = Join-Path $root 'windows'
$dist = Join-Path $win 'dist'
$app = Join-Path $dist 'NoGreenBack'
$layout = Join-Path $dist 'msix'

$csproj = Get-Content (Join-Path $win 'NoGreenBack\NoGreenBack.csproj') -Raw -Encoding UTF8
$version = [regex]::Match($csproj, '<Version>([^<]+)</Version>').Groups[1].Value
# MSIX の版は 4 つの数字。Store では 4 つ目を 0 にする決まり
$msixVersion = if ($version.Split('.').Count -eq 3) { "$version.0" } else { $version }

# 前に -Register で入れたものは、中身のフォルダを作り直す前に外す (入れたものはそのフォルダを指しているため)
if ($Register) { Get-AppxPackage -Name $Name | Remove-AppxPackage }

# 1. 中身を作る (zip と同じもの)
if (-not $SkipBuild) { & (Join-Path $PSScriptRoot 'make-release.ps1') }
if (-not (Test-Path (Join-Path $app 'NoGreenBack.exe'))) { throw "windows\dist\NoGreenBack がありません。make-release.ps1 を先に実行してください" }

# 2. MSIX の中身のフォルダ: アプリ ＋ 設定 (AppxManifest.xml) ＋ タイルの画像
if (Test-Path $layout) { Remove-Item $layout -Recurse -Force }
Copy-Item $app $layout -Recurse
Copy-Item (Join-Path $win 'Packaging\Images') (Join-Path $layout 'Images') -Recurse
$manifest = Get-Content (Join-Path $win 'Packaging\AppxManifest.xml') -Raw -Encoding UTF8
$manifest = $manifest.Replace('{{NAME}}', $Name)
$manifest = $manifest.Replace('{{PUBLISHER}}', [Security.SecurityElement]::Escape($Publisher))
$manifest = $manifest.Replace('{{PUBLISHER_DISPLAY_NAME}}', [Security.SecurityElement]::Escape($PublisherDisplayName))
$manifest = $manifest.Replace('{{VERSION}}', $msixVersion)
[IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'), $manifest, (New-Object Text.UTF8Encoding $false))

# 3. makeappx で .msix にまとめる (設定の書き方の誤りもここで見つかる)
$kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$makeappx = Get-ChildItem $kits -Recurse -Filter makeappx.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -eq 'x64' } | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $makeappx) { throw "makeappx.exe が見つかりません。Windows SDK を入れてください (Visual Studio Installer か winget install Microsoft.WindowsSDK.10.0.26100)" }
$msix = Join-Path $dist "NoGreenBack-Windows-$version.msix"
& $makeappx.FullName pack /d $layout /p $msix /o
if ($LASTEXITCODE -ne 0) { throw "MSIX にまとめられませんでした" }
"{0} ({1:N1} MB, 版 {2})" -f $msix, ((Get-Item $msix).Length / 1MB), $msixVersion

# 4. この PC に入れて試す (署名なしのまま。「設定 → システム → 開発者向け」で開発者モードをオンにしておく)
if ($Register) {
    Add-AppxPackage -Register (Join-Path $layout 'AppxManifest.xml')
    "入れました。スタートメニューの NoGreenBack から起動します。外すときは「設定 → アプリ」から (windows\dist\msix を消すと起動できなくなります)"
}
