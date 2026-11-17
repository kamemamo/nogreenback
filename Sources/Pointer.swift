// 指し棒: マウスカーソルの位置を矢印で指す、長さの決まった木の棒 (人物のいる側から斜めに差し出す)
// 画面に重ねるウインドウと、合成した映像 (全画面出力など) の両方で同じ絵を描く

import AppKit
import CoreImage

enum PointerRenderer {
    /// 棒の根元 (手で持つ端)。棒の長さは画面の高さの半分で決まっていて、先 (tip) から下へ伸ばす。
    /// 先が右にあるほど根元を右に出して左に傾け、左にあるほど根元を左に出して右に傾ける
    /// (真ん中ではまっすぐ立つ。画面の端で棒がはみ出すときは、収まる向きに回す)。座標は左下原点
    static func base(tip: CGPoint, in area: CGRect, right: Bool) -> CGPoint {
        let length = area.height * 0.5
        // 先の横の位置 (左端 0、右端 1)
        let f = min(max((tip.x - area.minX) / max(area.width, 1), 0), 1)
        // 縦からの傾き: 左端で -45 度 (根元が左)、右端で +45 度 (根元が右)
        let preferred = (f - 0.5) * 2 * 45
        // 棒が画面からはみ出して消えないよう、収まらなければ少しずつ回して、収まる向きにする
        let inner = area.insetBy(dx: area.height * 0.01, dy: area.height * 0.01)
        func base(_ degrees: CGFloat) -> CGPoint {
            let r = degrees * .pi / 180
            return CGPoint(x: tip.x + sin(r) * length, y: tip.y - cos(r) * length)
        }
        // まず根元を同じ側 (右を指していれば右) に保ったまま、近い向きから探す。
        // それで収まらないときだけ、反対側も使う
        let side: CGFloat = preferred >= 0 ? 1 : -1
        for sameSideOnly in [true, false] {
            for step in 0...90 {
                for sign in step == 0 ? [CGFloat(1)] : [CGFloat(1), -1] {
                    let deg = preferred + sign * CGFloat(step) * 2
                    if sameSideOnly && (deg * side < 0 || abs(deg) > 120) { continue }
                    let p = base(deg)
                    if inner.contains(p) { return p }
                }
            }
        }
        return base(preferred)
    }

    /// 棒を描く。size は画面 (映像) の高さ。太さや先の玉の大きさはこれに合わせる
    static func draw(in ctx: CGContext, from start: CGPoint, to tip: CGPoint, size: CGFloat) {
        let dx = tip.x - start.x, dy = tip.y - start.y
        let fullLength = hypot(dx, dy)
        guard fullLength > 1 else { return }
        // 棒の向きと、直角な向き
        let ux = dx / fullLength, uy = dy / fullLength
        let nx = -uy, ny = ux
        // 先は矢印。棒は矢印の付け根まで
        let headLength = size * 0.032, headHalf = size * 0.014
        let point = tip
        let tip = CGPoint(x: point.x - ux * headLength * 0.9, y: point.y - uy * headLength * 0.9)
        let baseW = size * 0.009, tipW = size * 0.004
        let p1 = CGPoint(x: start.x + nx * baseW, y: start.y + ny * baseW)
        let p2 = CGPoint(x: start.x - nx * baseW, y: start.y - ny * baseW)
        let p3 = CGPoint(x: tip.x - nx * tipW, y: tip.y - ny * tipW)
        let p4 = CGPoint(x: tip.x + nx * tipW, y: tip.y + ny * tipW)

        ctx.saveGState()
        // 影を付けて、画面から少し浮いて見えるように
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.002), blur: size * 0.008,
                      color: CGColor(gray: 0, alpha: 0.5))
        ctx.beginPath()
        ctx.addLines(between: [p1, p2, p3, p4])
        ctx.closePath()
        ctx.setFillColor(CGColor(red: 0.55, green: 0.36, blue: 0.2, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        // 木のつや (棒の片側に明るい筋)
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setStrokeColor(CGColor(red: 0.85, green: 0.68, blue: 0.48, alpha: 0.7))
        ctx.setLineWidth(max(1, size * 0.0025))
        ctx.move(to: CGPoint(x: start.x + nx * baseW * 0.45, y: start.y + ny * baseW * 0.45))
        ctx.addLine(to: CGPoint(x: tip.x + nx * tipW * 0.45, y: tip.y + ny * tipW * 0.45))
        ctx.strokePath()
        // ふち
        ctx.beginPath()
        ctx.addLines(between: [p1, p2, p3, p4])
        ctx.closePath()
        ctx.setStrokeColor(CGColor(red: 0.3, green: 0.18, blue: 0.08, alpha: 1))
        ctx.setLineWidth(max(1, size * 0.0012))
        ctx.strokePath()

        // 先の矢印 (先端がちょうどマウスの位置)
        let hb = CGPoint(x: point.x - ux * headLength, y: point.y - uy * headLength)
        let arrow = [point,
                     CGPoint(x: hb.x + nx * headHalf, y: hb.y + ny * headHalf),
                     CGPoint(x: hb.x - nx * headHalf, y: hb.y - ny * headHalf)]
        ctx.setShadow(offset: .zero, blur: size * 0.006, color: CGColor(gray: 0, alpha: 0.6))
        ctx.beginPath()
        ctx.addLines(between: arrow)
        ctx.closePath()
        ctx.setFillColor(CGColor(red: 0.85, green: 0.12, blue: 0.1, alpha: 1))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.beginPath()
        ctx.addLines(between: arrow)
        ctx.closePath()
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.setLineWidth(max(1, size * 0.0015))
        ctx.strokePath()
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
        if frame != screen.frame { setFrame(screen.frame, display: false) }
        let o = screen.frame.origin
        view.start = CGPoint(x: start.x - o.x, y: start.y - o.y)
        view.tip = CGPoint(x: tip.x - o.x, y: tip.y - o.y)
        view.needsDisplay = true
        if !isVisible { orderFrontRegardless() }
    }
}
