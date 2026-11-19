# Windows 版の配布用 zip を作る (SPEC.md 17 章 7: 試作は .NET を同梱した自己完結型の、署名なしの zip)
#   powershell -ExecutionPolicy Bypass -File windows\Tools\make-release.ps1
# できるもの: windows\dist\NoGreenBack-Windows-<版>.zip (中は NoGreenBack フォルダ)
# 人物の切り抜きのモデル (Apache-2.0) は同梱する。先に windows\models\download.ps1 を実行しておく。
# 字幕のモデルは同梱しない (初めて字幕をオンにしたときに取ってくる)。

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$win = Join-Path $root 'windows'
$proj = Join-Path $win 'NoGreenBack\NoGreenBack.csproj'
$dist = Join-Path $win 'dist'
$app = Join-Path $dist 'NoGreenBack'
$packages = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $HOME '.nuget\packages' }

$csproj = Get-Content $proj -Raw -Encoding UTF8
$version = [regex]::Match($csproj, '<Version>([^<]+)</Version>').Groups[1].Value
function PackageVersion($id) { [regex]::Match($csproj, "Include=""$id"" Version=""([^""]+)""").Groups[1].Value }

# モデルがそろっているか
$models = @('mediapipe_selfie_landscape.onnx', 'modnet.onnx')
foreach ($m in $models) {
    if (-not (Test-Path (Join-Path $win "models\$m"))) { throw "windows\models\$m がありません。先に windows\models\download.ps1 を実行してください" }
}

# 1. 自己完結型でビルドする
if (Test-Path $app) { Remove-Item $app -Recurse -Force }
dotnet publish $proj -c Release -r win-x64 --self-contained true -o $app
if ($LASTEXITCODE -ne 0) { throw "ビルドに失敗しました" }

# 2. Windows x64 で使わないもの (ほかの CPU・Linux の実行部分、デバッグ用の情報) を除く
foreach ($d in @('runtimes\win-arm64', 'runtimes\win-x86', 'runtimes\vulkan\linux-x64')) {
    $p = Join-Path $app $d
    if (Test-Path $p) { Remove-Item $p -Recurse -Force }
}
Get-ChildItem $app -Recurse -Filter *.pdb | Remove-Item -Force

# 3. モデルを同梱する (アプリは exe の隣の models フォルダから読む)
New-Item -ItemType Directory -Force (Join-Path $app 'models') | Out-Null
foreach ($m in $models) { Copy-Item (Join-Path $win "models\$m") (Join-Path $app "models\$m") }

# 4. ライセンス
$lic = Join-Path $app 'licenses'
New-Item -ItemType Directory -Force $lic | Out-Null
Copy-Item (Join-Path $root 'LICENSE') (Join-Path $lic 'NoGreenBack-LICENSE.txt')
$ort = Join-Path $packages ('microsoft.ml.onnxruntime.directml\' + (PackageVersion 'Microsoft.ML.OnnxRuntime.DirectML') + '\ThirdPartyNotices.txt')
Copy-Item $ort (Join-Path $lic 'ONNXRuntime-ThirdPartyNotices.txt')
$dml = Get-ChildItem (Join-Path $packages 'microsoft.ai.directml') -Directory | Sort-Object { [version]$_.Name } | Select-Object -Last 1
Copy-Item (Join-Path $dml.FullName 'LICENSE.txt') (Join-Path $lic 'DirectML-LICENSE.txt')
Copy-Item (Join-Path $dml.FullName 'ThirdPartyNotices.txt') (Join-Path $lic 'DirectML-ThirdPartyNotices.txt')
Copy-Item (Join-Path $packages ('whisper.net\' + (PackageVersion 'Whisper.net') + '\LICENSE')) (Join-Path $lic 'Whisper.net-LICENSE.txt')
# Apache License 2.0 の全文 (ONNX Runtime の ThirdPartyNotices に入っているものを取り出す)
$lines = Get-Content $ort -Encoding UTF8
$start = ($lines | Select-String -Pattern '^\s+Apache License\s*$' | Select-Object -First 1).LineNumber - 1
$end = ($lines | Select-Object -Skip $start | Select-String -Pattern 'limitations under the License\.' | Select-Object -First 1).LineNumber + $start - 1
$lines[$start..$end] | Set-Content (Join-Path $lic 'Apache-2.0.txt') -Encoding UTF8
Copy-Item (Join-Path $win 'Tools\release-notices.txt') (Join-Path $app 'THIRD-PARTY-NOTICES.txt')

# 5. zip にまとめる
$zip = Join-Path $dist "NoGreenBack-Windows-$version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($app, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)
"{0} ({1:N1} MB)" -f $zip, ((Get-Item $zip).Length / 1MB)
