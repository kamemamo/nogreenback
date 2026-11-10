// Syphon サーバー一覧を表示し、NoGreenBack から 1 フレーム受信して PNG に保存する確認ツール
// 使い方: syphon-check [出力PNGパス]
import AppKit
import CoreImage
import Metal
import Syphon

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "syphon-frame.png"
let device = MTLCreateSystemDefaultDevice()!

// サーバー一覧の更新を待つ
RunLoop.main.run(until: Date().addingTimeInterval(1.0))
let servers = SyphonServerDirectory.shared().servers
print("Syphon servers:")
for s in servers {
    print("  -", s[SyphonServerDescriptionAppNameKey] ?? "?", "/", s[SyphonServerDescriptionNameKey] ?? "?")
}
guard let desc = servers.first(where: { ($0[SyphonServerDescriptionNameKey] as? String) == "NoGreenBack" }) else {
    print("NoGreenBack サーバーが見つかりません"); exit(1)
}

let client = SyphonMetalClient(serverDescription: desc, device: device, options: nil, newFrameHandler: nil)
var tex: MTLTexture?
for _ in 0..<50 {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    if client.hasNewFrame, let t = client.newFrameImage() { tex = t; break }
}
guard let t = tex else { print("フレームを受信できません (カメラ許可待ち?)"); exit(2) }
print("受信: \(t.width)x\(t.height) \(t.pixelFormat == .bgra8Unorm ? "BGRA8" : "\(t.pixelFormat.rawValue)")")

// private ストレージかもしれないので shared テクスチャへコピー
let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: t.pixelFormat, width: t.width, height: t.height, mipmapped: false)
d.storageMode = .shared
let copy = device.makeTexture(descriptor: d)!
let q = device.makeCommandQueue()!, cb = q.makeCommandBuffer()!, blit = cb.makeBlitCommandEncoder()!
blit.copy(from: t, to: copy); blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()

var bytes = [UInt8](repeating: 0, count: t.width * t.height * 4)
copy.getBytes(&bytes, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
var transparent = 0, opaque = 0
for i in stride(from: 3, to: bytes.count, by: 4) {
    if bytes[i] == 0 { transparent += 1 } else if bytes[i] == 255 { opaque += 1 }
}
let n = Double(t.width * t.height)
print(String(format: "alpha: 透明 %.1f%% / 不透明 %.1f%% / 中間 %.1f%%",
             Double(transparent) / n * 100, Double(opaque) / n * 100, Double(Int(n) - transparent - opaque) / n * 100))

// 行 0 が画像の上端として PNG 化 (Syphon/Metal の規約)
let ci = CIImage(mtlTexture: copy, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])!
    .oriented(.downMirrored)
let ctx = CIContext()
try ctx.writePNGRepresentation(of: ci, to: URL(fileURLWithPath: outPath), format: .RGBA8,
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
print("保存: \(outPath)")
client.stop()
