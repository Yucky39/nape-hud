import AppKit

/// 状態レポートを一切吐かないファームウェア向けの保険経路。
///
/// Keychron Launcher 側で「レイヤー切替キーに F13〜F20 などのセンチネルキーを同時送出させる」
/// 設定にしておけば、接続方式（BT / 2.4GHz / 有線）に関係なく HID キーボードとして届くので、
/// ここで拾って HUD を出せる。consume: true ならそのキーは下流アプリに流さない。
final class KeyWatcher {
    private let bindings: [KeyBinding]
    private let consume: Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// (レイヤー, 角度, DPI) — 一致した割り当てのうち指定されているものだけが非 nil で渡る
    var onMatch: ((Int?, Int?, Int?) -> Void)?

    init(fallback: KeyFallback) {
        self.bindings = fallback.bindings
        self.consume = fallback.consume
    }

    func start() throws {
        guard !bindings.isEmpty else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,               // イベントを差し止められる位置
            eventsOfInterest: mask,
            callback: { _, type, event, ctx in
                guard let ctx else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<KeyWatcher>.fromOpaque(ctx).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: ctx
        ) else {
            throw Err("""
                キーイベントの監視を開始できませんでした。
                システム設定 → プライバシーとセキュリティ → アクセシビリティ で
                このアプリ（またはターミナル）を許可してください。
                """)
        }

        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // タップが重い処理でタイムアウト無効化された場合は復帰させる。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        for b in bindings where b.keyCode == code && modifiersMatch(b.modifiers, flags) {
            onMatch?(b.layer, b.angle, b.dpi)
            return consume ? nil : Unmanaged.passUnretained(event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func modifiersMatch(_ wanted: [String]?, _ flags: CGEventFlags) -> Bool {
        var need: CGEventFlags = []
        for m in wanted ?? [] {
            switch m.lowercased() {
            case "cmd", "command": need.insert(.maskCommand)
            case "opt", "option", "alt": need.insert(.maskAlternate)
            case "ctrl", "control": need.insert(.maskControl)
            case "shift": need.insert(.maskShift)
            case "fn", "function": need.insert(.maskSecondaryFn)
            default: break
            }
        }
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        return flags.intersection(relevant) == need
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func promptAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
