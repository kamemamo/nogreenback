// キーの操作を説明するための、キーボードの絵 (JIS 配列。Mac と Windows の両方の名前を書く)
// 映像に重ねたり画面に出したりして、手書きで「このキー」と示す

import AppKit
import CoreImage

enum KeyboardRenderer {
    /// キー 1 つ。位置と大きさは 1 キー分を 1 とした単位 (y は上から)
    struct Key {
        var mac: String
        /// Windows での名前 (nil なら Mac と同じ)
        var win: String? = nil
        var x: CGFloat
        var y: CGFloat
        var w: CGFloat = 1
        var h: CGFloat = 1
        /// 文字や数字 1 つのキー (大きな文字で出す)
        var big = false
        /// shift を押して出る文字 (キーの上の方に小さく出す)
        var shift: String? = nil
    }

    /// JIS 配列で shift を押して出る文字 (テンキー以外)
    static let shifted: [String: String] = [
        "1": "!", "2": "\"", "3": "#", "4": "$", "5": "%", "6": "&", "7": "'", "8": "(", "9": ")",
        "-": "=", "^": "~", "¥": "|", "@": "`", "[": "{", ";": "+", ":": "*", "]": "}",
        ",": "<", ".": ">", "/": "?",
    ]

    /// ファンクションキーの行の高さ
    static let fnRow: CGFloat = 0.55
    /// 本体の横幅、テンキーとの間、テンキーの横幅 (単位)
    static let mainWidth: CGFloat = 15
    static let numGap: CGFloat = 0.4
    static let numWidth: CGFloat = 4
    static var width: CGFloat { mainWidth + numGap + numWidth }
    static var height: CGFloat { fnRow + 5 }

    /// Mac のキーの記号
    static let symbols = ["shift": "⇧", "control": "⌃", "option": "⌥", "command": "⌘",
                          "tab": "⇥", "delete": "⌫", "return": "↩", "caps": "⇪"]

    static let keys: [Key] = {
        var keys: [Key] = []
        /// 左から順に並べる。items は (Mac の名前, Windows の名前, 幅)
        func row(_ y: CGFloat, h: CGFloat = 1, from x0: CGFloat = 0, _ items: [(String, String?, CGFloat)]) {
            var x = x0
            for (mac, win, w) in items {
                let big = win == nil && mac.count == 1
                // テンキーには shift の文字を付けない
                let shift = x < mainWidth ? shifted[mac] : nil
                keys.append(Key(mac: mac, win: win, x: x, y: y, w: w, h: h, big: big, shift: shift))
                x += w
            }
        }
        func chars(_ s: String) -> [(String, String?, CGFloat)] { s.map { (String($0), nil, 1) } }

        // ファンクションキー
        let fw = (mainWidth - 1.5) / 12
        row(0, h: fnRow, [("esc", nil, 1.5)] + (1...12).map { ("F\($0)", nil, fw) })
        let y1 = fnRow
        // 数字の行 (左端は Windows だけの 半角/全角)
        row(y1, [("", "半/全", 1)] + chars("1234567890-^¥") + [("delete", "BS", 1)])
        row(y1 + 1, [("tab", nil, 1.5)] + chars("QWERTYUIOP@["))          // 右端は return (別に描く)
        row(y1 + 2, [("control", "Caps", 1.75)] + chars("ASDFGHJKL;:]"))
        row(y1 + 3, [("shift", nil, 2.25)] + chars("ZXCVBNM,./") + [("_", "\\", 1), ("shift", nil, 1.75)])
        row(y1 + 4, [("caps", "Ctrl", 1), ("option", "Win", 1), ("command", "Alt", 1.25), ("英数", "無変換", 1.25),
                     ("", nil, 3.75), ("かな", "変換", 1.25), ("command", "Alt", 1.25), ("option", "Ctrl", 1.25)])
        // 矢印 (上下は半分の高さ)
        keys.append(Key(mac: "←", x: mainWidth - 3, y: y1 + 4.5, h: 0.5))
        keys.append(Key(mac: "↑", x: mainWidth - 2, y: y1 + 4, h: 0.5))
        keys.append(Key(mac: "↓", x: mainWidth - 2, y: y1 + 4.5, h: 0.5))
        keys.append(Key(mac: "→", x: mainWidth - 1, y: y1 + 4.5, h: 0.5))

        // テンキー (Windows の並び。+ と enter は 2 段分)
        let nx = mainWidth + numGap
        row(y1, from: nx, [("clear", "NumLk", 1), ("/", nil, 1), ("*", nil, 1), ("-", nil, 1)])
        row(y1 + 1, from: nx, chars("789"))
        row(y1 + 2, from: nx, chars("456"))
        row(y1 + 3, from: nx, chars("123"))
        row(y1 + 4, from: nx, [("0", nil, 2), (".", nil, 1)])
        keys.append(Key(mac: "+", x: nx + 3, y: y1 + 1, h: 2, big: true))
        keys.append(Key(mac: "enter", win: "Enter", x: nx + 3, y: y1 + 3, h: 2))
        return keys
    }()

    /// 横幅 width ピクセルのキーボードの画像
    static func image(width pixelWidth: CGFloat) -> CGImage? {
        let pad: CGFloat = 0.2
        let unit = (pixelWidth / (width + pad * 2)).rounded(.down)
        guard unit >= 4 else { return nil }
        let w = Int(((width + pad * 2) * unit).rounded()), h = Int(((height + pad * 2) * unit).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // 上から下へ並べたいので、左上を原点にする
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        defer { NSGraphicsContext.restoreGraphicsState() }

        // 下地
        let base = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)),
                                xRadius: unit * 0.3, yRadius: unit * 0.3)
        NSColor(white: 0.08, alpha: 0.78).setFill()
        base.fill()

        let gap = unit * 0.1
        let radius = unit * 0.14
        let winColor = NSColor(red: 0.55, green: 0.8, blue: 1, alpha: 1)
        func drawKey(_ path: NSBezierPath) {
            NSColor(white: 0.22, alpha: 0.95).setFill()
            path.fill()
            NSColor(white: 0.45, alpha: 1).setStroke()
            path.lineWidth = max(1, unit * 0.025)
            path.stroke()
        }
        func text(_ s: String, size: CGFloat, color: NSColor = .white, weight: NSFont.Weight = .medium) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            return NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
            ])
        }
        /// 文字を縦に並べて、キーの真ん中に置く (はみ出す文字は小さくする)
        func drawLines(_ lines: [NSAttributedString], in r: NSRect) {
            let maxW = r.width - unit * 0.12
            let lines = lines.map { line -> NSAttributedString in
                let lw = line.size().width
                guard lw > maxW, let font = line.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return line }
                let m = NSMutableAttributedString(attributedString: line)
                m.addAttribute(.font, value: font.withSize(font.pointSize * maxW / lw),
                               range: NSRange(location: 0, length: m.length))
                return m
            }
            let heights = lines.map { $0.size().height }
            var y = r.midY - heights.reduce(0, +) / 2
            for (line, lh) in zip(lines, heights) {
                line.draw(in: NSRect(x: r.minX, y: y, width: r.width, height: lh))
                y += lh
            }
        }
        func drawLabel(_ key: Key, in r: NSRect) {
            if key.big, let shift = key.shift {
                // shift の文字を上に、ふだんの文字を下に
                drawLines([text(shift, size: unit * 0.26, color: NSColor(white: 0.8, alpha: 1)),
                           text(key.mac, size: unit * 0.34, weight: .semibold)], in: r)
                return
            }
            if key.big {
                drawLines([text(key.mac, size: unit * 0.4, weight: .semibold)], in: r)
                return
            }
            var lines: [NSAttributedString] = []
            if !key.mac.isEmpty {
                let name = symbols[key.mac].map { "\($0) \(key.mac)" } ?? key.mac
                lines.append(text(name, size: unit * 0.21))
            }
            if let win = key.win { lines.append(text(win, size: unit * 0.21, color: winColor)) }
            drawLines(lines, in: r)
        }

        for key in keys {
            let r = NSRect(x: (pad + key.x) * unit + gap / 2, y: (pad + key.y) * unit + gap / 2,
                           width: key.w * unit - gap, height: key.h * unit - gap)
            drawKey(NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius))
            drawLabel(key, in: r)
        }

        // return (JIS は 2 行にまたがる L 字)
        let top = (pad + fnRow + 1) * unit + gap / 2
        let right = (pad + mainWidth) * unit - gap / 2
        let upperLeft = (pad + 13.5) * unit + gap / 2
        let lowerLeft = (pad + 13.75) * unit + gap / 2
        let mid = top + unit - gap
        let bottom = top + 2 * unit - gap
        let ret = NSBezierPath()
        ret.move(to: NSPoint(x: upperLeft, y: top))
        ret.line(to: NSPoint(x: right, y: top))
        ret.line(to: NSPoint(x: right, y: bottom))
        ret.line(to: NSPoint(x: lowerLeft, y: bottom))
        ret.line(to: NSPoint(x: lowerLeft, y: mid))
        ret.line(to: NSPoint(x: upperLeft, y: mid))
        ret.close()
        drawKey(ret)
        drawLabel(Key(mac: "return", win: "Enter", x: 0, y: 0),
                  in: NSRect(x: lowerLeft, y: top, width: right - lowerLeft, height: bottom - top))
        return ctx.makeImage()
    }

    /// 置く場所
    enum Position: Int, CaseIterable {
        /// 人物の反対側の下 (人物が右なら左下、左なら右下)
        case auto, bottom, bottomLeft, bottomRight, top
        var title: String { ["人物の反対側", "下の中央", "左下", "右下", "上の中央"][rawValue] }
    }

    /// 領域 area の中で、キーボードを置く枠 (左下原点)
    static func frame(size: CGSize, in area: CGRect, position: Position) -> CGRect {
        let margin = area.height * 0.03
        let x: CGFloat
        switch position {
        case .bottomLeft: x = area.minX + margin
        case .bottomRight: x = area.maxX - size.width - margin
        case .bottom, .top, .auto: x = area.midX - size.width / 2
        }
        let y = position == .top ? area.maxY - size.height - margin : area.minY + margin
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
    }

    /// 映像 (extent) に重ねるキーボード。scale は映像の横幅に対する割合
    static func ciImage(extent: CGRect, scale: Double, position: Position) -> CIImage? {
        guard let cg = image(width: extent.width * CGFloat(scale)) else { return nil }
        let img = CIImage(cgImage: cg)
        let f = frame(size: img.extent.size, in: extent, position: position)
        return img.transformed(by: CGAffineTransform(translationX: f.minX, y: f.minY))
    }
}

/// デスクトップに出すキーボード (全画面出力を使わず、画面に重ねる表示や画面の録画で使うとき)。
/// 手書きの線より下、クリックは後ろのアプリに届く
final class KeyboardWindow: NSPanel {
    private let imageView = NSImageView()
    private var cacheKey = ""

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        imageView.imageScaling = .scaleAxesIndependently
        contentView = imageView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        // 人物の表示と同じ層 (手書きの線はその 1 つ上なので、キーボードの上に描ける)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(on screen: NSScreen?, scale: Double, position: KeyboardRenderer.Position) {
        guard let screen else { orderOut(nil); return }
        let sf = screen.frame
        let bs = screen.backingScaleFactor
        let key = "\(sf.width)x\(sf.height)@\(bs) \(scale)"
        if key != cacheKey, let cg = KeyboardRenderer.image(width: sf.width * CGFloat(scale) * bs) {
            cacheKey = key
            imageView.image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / bs,
                                                               height: CGFloat(cg.height) / bs))
        }
        guard let size = imageView.image?.size else { orderOut(nil); return }
        setFrame(KeyboardRenderer.frame(size: size, in: sf, position: position), display: true)
        orderFrontRegardless()
    }
}
