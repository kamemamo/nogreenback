// 指し棒: マウスカーソルの位置を矢印で指す、長さの決まった棒
// 画面に重ねるウインドウと、合成した映像 (全画面出力など) の両方で同じ絵を描く

import AppKit
import CoreImage

enum PointerRenderer {
    /// 棒の長さ (画面の高さに対する割合)
    static let lengthRatio: CGFloat = 0.45

    /// 棒の傾き (度。縦から、正なら根元が右)。棒はいつも矢印の右下 (0〜90 度) に出して、左上を指す形にする。
    /// 左の方を指すほど少し寝かせる。画面の下の辺や右の辺にかかるときだけ、収まる向きに回す
    static func angle(tip: CGPoint, in area: CGRect) -> CGFloat {
        // 先の横の位置 (左端 0、右端 1)
        let f = min(max((tip.x - area.minX) / max(area.width, 1), 0), 1)
        // 左端で 40 度、右端で 25 度 (どちらも根元が右)
        let preferred = 40 - 15 * f
        let inner = area.insetBy(dx: area.height * 0.01, dy: area.height * 0.01)
        let length = area.height * lengthRatio
        // 根元が下の辺にかからないための、いちばん小さい傾き (寝かせるほど根元が上がる。90 度で横向き)
        let lo = acos(min(max((tip.y - inner.minY) / length, 0), 1)) * 180 / .pi
        // 根元が右の辺にかからないための、いちばん大きい傾き
        let hi = asin(min(max((inner.maxX - tip.x) / length, 0), 1)) * 180 / .pi
        // 収まる向きがあれば、その中で好みの傾きにいちばん近いもの。
        // 右下の隅のように収まる向きがないときは、上や左には回さず、棒の一部をそのまま画面の外に出す
        // (隅に入るときも出るときも、傾きはなめらかにつながる)
        return lo <= hi ? min(max(preferred, lo), hi) : min(max(preferred, hi), lo)
    }

    /// 傾き angle (度) のときの棒の根元 (手で持つ端)。座標は左下原点
    static func base(tip: CGPoint, angle: CGFloat, in area: CGRect) -> CGPoint {
        let length = area.height * lengthRatio
        let r = angle * .pi / 180
        return CGPoint(x: tip.x + sin(r) * length, y: tip.y - cos(r) * length)
    }

    /// 棒を描く (白い縁の付いた黒い細い棒と、先の白い矢印 (黒い縁))。size は画面 (映像) の高さ
    static func draw(in ctx: CGContext, from start: CGPoint, to point: CGPoint, size: CGFloat) {
        let dx = point.x - start.x, dy = point.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        // 先は矢印 (先端がちょうどマウスの位置)。棒は矢印の付け根まで
        let headLength = size * 0.055, headHalf = size * 0.022
        let hb = CGPoint(x: point.x - ux * headLength, y: point.y - uy * headLength)
        let end = CGPoint(x: hb.x + ux * headLength * 0.2, y: hb.y + uy * headLength * 0.2)

        ctx.saveGState()
        ctx.setLineCap(.round)
        // 棒: 半透明の白い縁の上に黒い棒 (明るい画面では黒い棒が、暗い画面では白い縁が見える)
        for (width, color) in [(size * 0.0225, CGColor(gray: 1, alpha: 0.6)),
                               (size * 0.0125, CGColor(gray: 0.16, alpha: 1))] {
            ctx.setLineWidth(width)
            ctx.setStrokeColor(color)
            ctx.move(to: start)
            ctx.addLine(to: end)
            ctx.strokePath()
        }
        // 矢印: 白く塗って黒い縁を付ける (明るい画面でも暗い画面でも形がわかる)
        ctx.beginPath()
        ctx.addLines(between: [point,
                               CGPoint(x: hb.x + nx * headHalf, y: hb.y + ny * headHalf),
                               CGPoint(x: hb.x - nx * headHalf, y: hb.y - ny * headHalf)])
        ctx.closePath()
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 1))
        ctx.setLineWidth(max(1, size * 0.003))
        ctx.setLineJoin(.round)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }

    /// 映像 (extent) に重ねる指し棒の画像。棒のまわりだけの小さな画像にする
    static func ciImage(extent: CGRect, from start: CGPoint, to tip: CGPoint) -> CIImage? {
        let size = extent.height
        let pad = size * 0.03
        let rect = CGRect(x: min(start.x, tip.x) - pad, y: min(start.y, tip.y) - pad,
                          width: abs(tip.x - start.x) + pad * 2, height: abs(tip.y - start.y) + pad * 2)
            .intersection(extent).integral
        guard rect.width >= 1, rect.height >= 1,
              let ctx = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        draw(in: ctx, from: start, to: tip, size: size)
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}

/// 画面を覆う透明なビューに、指し棒を描く
final class PointerView: NSView {
    var start: CGPoint = .zero
    var tip: CGPoint = .zero

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        PointerRenderer.draw(in: ctx, from: start, to: tip, size: bounds.height)
    }
}

/// マウスがある画面を覆うパネル。クリックは後ろのアプリに届く
final class PointerWindow: NSPanel {
    let view = PointerView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = view
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        // 手書きの線よりさらに上
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// screen の上で、start (根元) から tip (先) まで棒を描く。座標は画面全体 (左下原点)
    func show(on screen: NSScreen, from start: CGPoint, to tip: CGPoint) {
        let moved = frame != screen.frame
        if moved { setFrame(screen.frame, display: false) }
        let o = screen.frame.origin
        // 描き直すのは、前の棒と新しい棒のまわりだけ (画面全体を 60 回/秒描き直さないように)
        let old = stickBounds(view.start, view.tip)
        view.start = CGPoint(x: start.x - o.x, y: start.y - o.y)
        view.tip = CGPoint(x: tip.x - o.x, y: tip.y - o.y)
        if moved || !isVisible {
            view.needsDisplay = true
        } else {
            view.setNeedsDisplay(old.union(stickBounds(view.start, view.tip)))
        }
        if !isVisible { orderFrontRegardless() }
    }

    /// 棒と矢印と影が入る範囲 (ビューの座標)
    private func stickBounds(_ a: CGPoint, _ b: CGPoint) -> NSRect {
        let pad = view.bounds.height * 0.04
        return NSRect(x: min(a.x, b.x) - pad, y: min(a.y, b.y) - pad,
                      width: abs(a.x - b.x) + pad * 2, height: abs(a.y - b.y) + pad * 2)
    }
}

/// 指し棒を出している間、マウスカーソルを隠す (矢印の先がカーソルの代わり)。
/// ほかのアプリが前にあっても隠せるよう、macOS の非公開の設定 (SetsCursorInBackground) を使う
enum CursorHider {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private static var hidden = false

    private static func allowInBackground() {
        let h = dlopen(nil, RTLD_NOW)
        guard let c = dlsym(h, "_CGSDefaultConnection"), let p = dlsym(h, "CGSSetConnectionProperty") else { return }
        let cid = unsafeBitCast(c, to: DefaultConnection.self)()
        _ = unsafeBitCast(p, to: SetProperty.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    static func hide() {
        guard !hidden else { return }
        hidden = true
        allowInBackground()
        CGDisplayHideCursor(CGMainDisplayID())
    }

    /// 隠している間に macOS がカーソルを出したとき (操作ウィンドウでポップアップのメニューを選んだときなど) に、
    /// 隠し直す。カーソルが出ているかは調べられない (調べる関数は今の macOS で使えない) ので、
    /// いったん出してから隠す。出ていなかったときも、隠したままで回数も変わらない
    static func rehide() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        CGDisplayHideCursor(CGMainDisplayID())
    }

    static func show() {
        guard hidden else { return }
        hidden = false
        CGDisplayShowCursor(CGMainDisplayID())
    }
}
