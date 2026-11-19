# 人物の切り抜きのモデルを Hugging Face から取ってくる (どれも Apache-2.0、合わせて約 26 MB)。
# Fast は MediaPipe、Balanced と Accurate は MODNet を入力の大きさを変えて使う (SPEC.md 17 章 2)。
# モデルは git に入れないので、取り出した直後にこれを 1 回実行する:
#   powershell -ExecutionPolicy Bypass -File windows\models\download.ps1
# 版を固定するため、URL にはリポジトリのコミットを入れている。

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$models = @(
    # MediaPipe Selfie Segmentation (landscape, 256x144)
    @{ Name = 'mediapipe_selfie_landscape.onnx'; Size = 462338;
       Url = 'https://huggingface.co/onnx-community/mediapipe_selfie_segmentation_landscape/resolve/2497d5bec26c626c7b3c4edc6e1fefc21b64f6c3/onnx/model.onnx' },
    # MODNet (portrait matting、入力の大きさは 32 の倍数なら自由)
    @{ Name = 'modnet.onnx'; Size = 25888640;
       Url = 'https://huggingface.co/Xenova/modnet/resolve/fa2fa546052fba4c08921230a26cc69a333fca12/onnx/model.onnx' }
)

foreach ($m in $models) {
    $path = Join-Path $here $m.Name
    if ((Test-Path $path) -and (Get-Item $path).Length -eq $m.Size) { "ある: $($m.Name)"; continue }
    "取ってくる: $($m.Name)"
    Invoke-WebRequest -Uri $m.Url -OutFile "$path.part" -UseBasicParsing
    $size = (Get-Item "$path.part").Length
    if ($size -ne $m.Size) { Remove-Item "$path.part"; throw "$($m.Name) の大きさが違います ($size / $($m.Size))" }
    Move-Item "$path.part" $path -Force
}
