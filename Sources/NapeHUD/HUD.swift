import AppKit

// MARK: - 表示内容

struct HUDContent {
    var title: String            // 例 "Layer 3"
    var subtitle: String         // 例 "Scroll"
    var angle: Int?              // 度数（0...359）。nil なら角度ダイヤルを描かない
    /// 主役以外の現在値（レイヤー名 / 角度 / DPI など）。" · " 区切りで 1 行に並ぶ
    var meta: [String] = []
    var connection: String?      // 例 "USB-C"
    var accent: NSColor = .controlAccentColor

    /// meta と接続バッジを連結した実際の表示文字列
    var metaLine: String {
        (meta + [connection].compactMap { $0 }).joined(separator: "   ·   ")
    }
}

// MARK: - オーバーレイウィンドウ

final class HUD {
    private var panel: NSPanel?
    private let view = HUDView()
    private var hideTimer: Timer?
    private let config: HUDConfig

    init(config: HUDConfig) { self.config = config }

    func show(_ content: HUDContent) {
        let panel = ensurePanel()
        view.content = content
        view.showDial = config.hud_showAngleDial
        let size = view.intrinsicSize(scale: config.scale)
        panel.setContentSize(size)
        reposition(panel, size: size)
        view.needsDisplay = true

        hideTimer?.invalidate()
        panel.alphaValue = panel.isVisible ? panel.alphaValue : 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        hideTimer = Timer.scheduledTimer(withTimeInterval: config.seconds, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            if panel.alphaValue < 0.01 { panel.orderOut(nil) }
        }
    }

    // MARK: -

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        // フルスクリーンアプリの上にも出したいので screenSaver レベル。
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        view.autoresizingMask = [.width, .height]
        blur.addSubview(view)
        view.frame = blur.bounds
        p.contentView = blur

        panel = p
        return p
    }

    private func reposition(_ panel: NSPanel, size: NSSize) {
        let screen: NSScreen? = {
            if config.followsMouseScreen {
                let loc = NSEvent.mouseLocation
                if let s = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) { return s }
            }
            return NSScreen.main ?? NSScreen.screens.first
        }()
        guard let f = screen?.visibleFrame else { return }
        let m = config.margin
        var origin: NSPoint
        switch config.position.lowercased() {
        case "center":
            origin = NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2)
        case "top":
            origin = NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - m)
        case "topleft":
            origin = NSPoint(x: f.minX + m, y: f.maxY - size.height - m)
        case "bottomleft":
            origin = NSPoint(x: f.minX + m, y: f.minY + m)
        case "bottomright":
            origin = NSPoint(x: f.maxX - size.width - m, y: f.minY + m)
        case "bottom":
            origin = NSPoint(x: f.midX - size.width / 2, y: f.minY + m)
        default: // topRight
            origin = NSPoint(x: f.maxX - size.width - m, y: f.maxY - size.height - m)
        }
        panel.setFrameOrigin(origin)
    }
}

// HUDConfig に後から足した項目を安全に読むための小さな橋渡し。
private extension HUDConfig {
    var hud_showAngleDial: Bool { showAngleDial }
}

// MARK: - 描画

final class HUDView: NSView {
    var content = HUDContent(title: "", subtitle: "", angle: nil)
    var showDial = true
    private var scale: Double = 1.0

    override var isOpaque: Bool { false }
    override var allowsVibrancy: Bool { true }

    func intrinsicSize(scale: Double) -> NSSize {
        self.scale = scale
        let dial = (showDial && content.angle != nil) ? 92.0 : 0.0
        let titleFont = NSFont.systemFont(ofSize: 13 * scale, weight: .semibold)
        let subFont = NSFont.systemFont(ofSize: 26 * scale, weight: .bold)
        let tw = width(content.title.uppercased(), titleFont)
        let sw = width(content.subtitle, subFont)
        let mw = width(content.metaLine, NSFont.systemFont(ofSize: 11 * scale, weight: .medium))
        let textW = max(tw, sw, mw)
        let w = (24 + dial * scale + (dial > 0 ? 18 : 0) + textW + 26) * 1.0
        let h = max(96 * scale, (dial + 28) * scale)
        return NSSize(width: min(max(w, 220 * scale), 520 * scale), height: h)
    }

    private func width(_ s: String, _ f: NSFont) -> Double {
        guard !s.isEmpty else { return 0 }
        return (s as NSString).size(withAttributes: [.font: f]).width
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let s = scale

        // 内側のうっすらした縁取り（HUD material 上での輪郭出し）
        let stroke = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18)
        NSColor.white.withAlphaComponent(0.10).setStroke()
        stroke.lineWidth = 1
        stroke.stroke()

        var textX = 24.0 * s

        // 角度ダイヤル
        if showDial, let angle = content.angle {
            let d = 66.0 * s
            let rect = NSRect(x: 22 * s, y: (b.height - d) / 2, width: d, height: d)
            drawDial(ctx, in: rect, angle: angle, accent: content.accent, scale: s)
            textX = rect.maxX + 20 * s
        }

        let meta = content.metaLine
        let titleFont = NSFont.systemFont(ofSize: 13 * s, weight: .semibold)
        let subFont = NSFont.systemFont(ofSize: 26 * s, weight: .bold)
        let metaFont = NSFont.systemFont(ofSize: 11 * s, weight: .medium)

        let titleH = 16.0 * s, subH = 32.0 * s, metaH = meta.isEmpty ? 0 : 15.0 * s
        let block = titleH + subH + metaH + (meta.isEmpty ? 4 : 6) * s
        var y = b.midY + block / 2 - titleH

        draw(content.title.uppercased(), at: NSPoint(x: textX, y: y), font: titleFont,
             color: content.accent, tracking: 1.2 * s)
        y -= subH
        draw(content.subtitle, at: NSPoint(x: textX, y: y), font: subFont,
             color: NSColor.labelColor)
        if !meta.isEmpty {
            y -= metaH + 2 * s
            draw(meta, at: NSPoint(x: textX, y: y), font: metaFont,
                 color: NSColor.secondaryLabelColor, tracking: 0.4 * s)
        }
    }

    private func draw(_ s: String, at p: NSPoint, font: NSFont, color: NSColor, tracking: Double = 0) {
        guard !s.isEmpty else { return }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if tracking != 0 { attrs[.kern] = tracking }
        (s as NSString).draw(at: p, withAttributes: attrs)
    }

    /// 8 方位の目盛りと、現在角度を指す針。OctaShift の 45° 刻みが見て分かるようにする。
    private func drawDial(_ ctx: CGContext, in rect: NSRect, angle: Int, accent: NSColor, scale s: Double) {
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let r = rect.width / 2

        // 外周
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 1.5 * s
        NSColor.white.withAlphaComponent(0.16).setStroke()
        ring.stroke()

        // 45° 刻みの目盛り
        for step in 0..<8 {
            let deg = Double(step) * 45
            let isCurrent = abs(normalize(Double(angle)) - deg) < 0.5
            let rad = (90 - deg) * .pi / 180
            let inner = r - (isCurrent ? 11 : 7) * s
            let outer = r - 3.5 * s
            let p = NSBezierPath()
            p.move(to: NSPoint(x: c.x + cos(rad) * inner, y: c.y + sin(rad) * inner))
            p.line(to: NSPoint(x: c.x + cos(rad) * outer, y: c.y + sin(rad) * outer))
            p.lineWidth = (isCurrent ? 2.6 : 1.4) * s
            p.lineCapStyle = .round
            (isCurrent ? accent : NSColor.white.withAlphaComponent(0.22)).setStroke()
            p.stroke()
        }

        // 針
        let rad = (90 - normalize(Double(angle))) * .pi / 180
        let tip = NSPoint(x: c.x + cos(rad) * (r - 15 * s), y: c.y + sin(rad) * (r - 15 * s))
        let tail = NSPoint(x: c.x - cos(rad) * 7 * s, y: c.y - sin(rad) * 7 * s)
        let needle = NSBezierPath()
        needle.move(to: tail)
        needle.line(to: tip)
        needle.lineWidth = 3.2 * s
        needle.lineCapStyle = .round
        accent.setStroke()
        needle.stroke()

        // 中心のハブ
        let hub = 5.0 * s
        let hubRect = NSRect(x: c.x - hub / 2, y: c.y - hub / 2, width: hub, height: hub)
        accent.setFill()
        NSBezierPath(ovalIn: hubRect).fill()
    }

    private func normalize(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }
}
