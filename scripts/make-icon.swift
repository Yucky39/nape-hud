// アプリアイコン(.icns)を生成する。
// HUD に描いている「8 方位ダイヤル + 針」をそのままアイコンの意匠に使う。
//
//   swift scripts/make-icon.swift <出力先.icns>

import AppKit
import Foundation

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "NapeHUD.icns"

/// 1 枚描く。macOS のアイコンは余白（全体の約 1/10）を残すのが慣習。
///
/// NSImage.lockFocus() はウインドウサーバに繋がっていないコマンドラインでは失敗するため、
/// NSBitmapImageRep に対して明示的に描画コンテキストを張る。
func render(size: Int) -> Data? {
    let px = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: px, height: px)

    guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    let saved = NSGraphicsContext.current
    NSGraphicsContext.current = gc
    defer { NSGraphicsContext.current = saved }

    let ctx = gc.cgContext
    ctx.setAllowsAntialiasing(true)

    let inset = px * 0.08
    let rect = NSRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
    let radius = rect.width * 0.235   // macOS の角丸に近い比率

    // 背景（濃紺 → 黒のグラデーション）
    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    bg.addClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.28, alpha: 1),
        NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.11, alpha: 1),
    ])
    gradient?.draw(in: rect, angle: 270)

    let c = NSPoint(x: rect.midX, y: rect.midY)
    let r = rect.width * 0.30
    let accent = NSColor(calibratedRed: 0.35, green: 0.78, blue: 1.0, alpha: 1)

    // 外周リング
    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    ring.lineWidth = max(1, px * 0.018)
    NSColor.white.withAlphaComponent(0.22).setStroke()
    ring.stroke()

    // 45° 刻みの目盛り（現在方向は 45°＝右上を強調）
    let currentStep = 1
    for step in 0..<8 {
        let deg = Double(step) * 45
        let rad = (90 - deg) * .pi / 180
        let isCurrent = step == currentStep
        let inner = r - px * (isCurrent ? 0.075 : 0.048)
        let outer = r - px * 0.018
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x + CGFloat(cos(rad)) * inner, y: c.y + CGFloat(sin(rad)) * inner))
        p.line(to: NSPoint(x: c.x + CGFloat(cos(rad)) * outer, y: c.y + CGFloat(sin(rad)) * outer))
        p.lineWidth = px * (isCurrent ? 0.032 : 0.016)
        p.lineCapStyle = .round
        (isCurrent ? accent : NSColor.white.withAlphaComponent(0.28)).setStroke()
        p.stroke()
    }

    // 針（右上 45° を指す）
    let rad = (90 - Double(currentStep) * 45) * .pi / 180
    let needle = NSBezierPath()
    needle.move(to: NSPoint(x: c.x - CGFloat(cos(rad)) * r * 0.22,
                            y: c.y - CGFloat(sin(rad)) * r * 0.22))
    needle.line(to: NSPoint(x: c.x + CGFloat(cos(rad)) * r * 0.66,
                            y: c.y + CGFloat(sin(rad)) * r * 0.66))
    needle.lineWidth = px * 0.038
    needle.lineCapStyle = .round
    accent.setStroke()
    needle.stroke()

    // 中心のハブ
    let hub = px * 0.055
    accent.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - hub / 2, y: c.y - hub / 2, width: hub, height: hub)).fill()

    gc.flushGraphics()
    return rep.representation(using: .png, properties: [:])
}

// iconutil が要求するファイル名の組
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let fm = FileManager.default
let work = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("nape-hud-icon-\(ProcessInfo.processInfo.processIdentifier)")
let iconset = work.appendingPathComponent("NapeHUD.iconset")

try? fm.removeItem(at: work)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for v in variants {
    guard let data = render(size: v.size) else {
        FileHandle.standardError.write("描画に失敗: \(v.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent("\(v.name).png"))
}

let out = URL(fileURLWithPath: outPath)
try? fm.removeItem(at: out)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: work)

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil が失敗しました\n".data(using: .utf8)!)
    exit(1)
}
print("アイコンを生成: \(out.path)")
