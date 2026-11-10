// SVG アイコンを透過を保ったまま描画し、AppIcon.icns を作るツール
// 使い方: render-icon <入力.svg> <出力.icns>
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: render-icon <in.svg> <out.icns>"); exit(1) }
let svgURL = URL(fileURLWithPath: args[1])
let icnsURL = URL(fileURLWithPath: args[2])
let svg = try String(contentsOf: svgURL, encoding: .utf8)

final class Renderer: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    var done: ((NSImage) -> Void)?

    func render(_ svg: String, completion: @escaping (NSImage) -> Void) {
        done = completion
        web.setValue(false, forKey: "drawsBackground")   // 背景を透明に
        web.navigationDelegate = self
        let html = """
        <html><head><style>html,body{margin:0;padding:0;background:transparent}
        svg{display:block;width:1024px;height:1024px}</style></head><body>\(svg)</body></html>
        """
        web.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // フォント描画が落ち着くまで少し待つ
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let cfg = WKSnapshotConfiguration()
            cfg.rect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
            webView.takeSnapshot(with: cfg) { img, err in
                guard let img else { print("snapshot failed: \(String(describing: err))"); exit(1) }
                self.done?(img)
            }
        }
    }
}

func png(_ image: NSImage, size px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: px, height: px).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let app = NSApplication.shared
let renderer = Renderer()
renderer.render(svg) { image in
    let fm = FileManager.default
    let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
    try? fm.removeItem(at: iconset)
    try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try! png(image, size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        try! png(image, size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    // 確認用に 1024px の PNG も出力先の隣に置く
    try! png(image, size: 1024).write(to: icnsURL.deletingPathExtension().appendingPathExtension("png"))

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
    try! p.run(); p.waitUntilExit()
    try? fm.removeItem(at: iconset)
    print(p.terminationStatus == 0 ? "作成: \(icnsURL.path)" : "iconutil failed")
    exit(p.terminationStatus)
}
app.run()
