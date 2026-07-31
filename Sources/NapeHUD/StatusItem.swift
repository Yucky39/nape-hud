import AppKit

/// メニューバー常駐項目。
///
/// LSUIElement（Dock に出ない常駐アプリ）はウインドウを持たないため、
/// これが無いと終了手段が Activity Monitor しか無くなる。
/// 同時に、ターミナルを見ていないときは気づけない現在値と警告を出す場所も兼ねる。
final class StatusItemController {
    private let item: NSStatusItem
    private let menu = NSMenu()

    /// 状態表示用の（選択できない）項目
    private let stateItem = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
    private let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let connectionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let warningItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let accelItem = NSMenuItem(title: "ポインタ加速", action: nil, keyEquivalent: "")

    var onShowNow: (() -> Void)?
    var onTest: (() -> Void)?
    var onCalibrate: (() -> Void)?
    var onShowKeymap: (() -> Void)?
    /// ポインタ加速の入り切り。戻り値は切り替え後の状態。
    /// 設定していない（= 加速が動いていない）ときは項目を出さない。
    var onToggleAcceleration: (() -> Bool)?
    var onOpenSettings: (() -> Void)?
    var onOpenConfig: (() -> Void)?
    var onRelaunch: (() -> Void)?

    /// メニューバーに現在のレイヤー番号を添えるか
    private let showsLayerBadge: Bool

    init(showsLayerBadge: Bool = true) {
        self.showsLayerBadge = showsLayerBadge
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = item.button {
            button.image = Self.templateIcon()
            button.imagePosition = .imageLeading
            button.toolTip = "nape-hud"
        }

        for i in [stateItem, detailItem, connectionItem] {
            i.isEnabled = false
            menu.addItem(i)
        }
        warningItem.isEnabled = false
        warningItem.isHidden = true
        menu.addItem(warningItem)

        menu.addItem(.separator())
        add("いまの状態を表示", #selector(showNow))
        add("HUD のテスト表示", #selector(test))
        accelItem.target = self
        accelItem.action = #selector(toggleAcceleration)
        accelItem.isHidden = true
        menu.addItem(accelItem)

        menu.addItem(.separator())
        add("キーアサインを表示…", #selector(showKeymap))
        add("向きを校正…", #selector(calibrate))
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        add("設定ファイルを開く", #selector(openConfig))
        add("設定を再読み込み（再起動）", #selector(relaunch))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "nape-hud を終了", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    private func add(_ title: String, _ selector: Selector) {
        let i = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        i.target = self
        menu.addItem(i)
    }

    // MARK: - 表示更新

    /// - Parameters:
    ///   - headline: 例 "Layer 3 — Media"
    ///   - detail:   例 "90° 縦置き  ·  1600 DPI"
    ///   - connection: 例 "USB-C"（未接続なら nil）
    ///   - layerBadge: メニューバーに出す短い文字列（例 "3"）
    func update(headline: String, detail: String, connection: String?, layerBadge: String?) {
        stateItem.title = headline
        detailItem.title = detail.isEmpty ? " " : detail
        detailItem.isHidden = detail.isEmpty
        connectionItem.title = connection.map { "接続: \($0)" } ?? "未接続"

        if showsLayerBadge, let badge = layerBadge {
            item.button?.title = " \(badge)"
        } else {
            item.button?.title = ""
        }
    }

    /// 対応表の設定漏れなど、ターミナルを見ていないと気づけない警告をここに出す。
    func showWarning(_ text: String?) {
        guard let text, !text.isEmpty else {
            warningItem.isHidden = true
            return
        }
        warningItem.title = "⚠️ \(text)"
        warningItem.isHidden = false
    }

    // MARK: - アクション

    @objc private func showNow() { onShowNow?() }
    @objc private func test() { onTest?() }
    @objc private func calibrate() { onCalibrate?() }
    @objc private func showKeymap() { onShowKeymap?() }

    /// 加速が動いているときだけ項目を出す（設定で無効なら存在しない機能なので隠す）
    func setAcceleration(enabled: Bool) {
        accelItem.isHidden = false
        accelItem.state = enabled ? .on : .off
    }

    @objc private func toggleAcceleration() {
        guard let now = onToggleAcceleration?() else { return }
        accelItem.state = now ? .on : .off
    }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openConfig() { onOpenConfig?() }
    @objc private func relaunch() { onRelaunch?() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: -

    /// メニューバー用のアイコン。テンプレート画像にしてダークモードに追従させる。
    private static func templateIcon() -> NSImage? {
        // 8 方位を示す記号を優先し、無い環境では順に代替する
        for name in ["dot.circle.viewfinder", "location.north.circle", "circle.grid.cross"] {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "nape-hud") {
                img.isTemplate = true
                return img
            }
        }
        return nil
    }
}
