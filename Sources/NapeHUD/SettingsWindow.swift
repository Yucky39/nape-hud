import AppKit

/// 設定画面。
///
/// 全項目は出さない。**日常的に触るもの**（表示の見た目・加速のカーブ・レイヤー名）だけを
/// 扱い、復号ルールやデバイス照合のような低頻度・専門的な項目は
/// 「設定ファイルを開く」で JSON を直接編集してもらう。
///
/// 保存はコメント付き JSON を壊さないよう、該当箇所だけを置換する（ConfigWriter）。
final class SettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private let configURL: URL
    private var config: Config

    /// 加速の値を触ったら即座に反映する（効き具合は動かして確かめるものなので）
    var onAccelerationChanged: ((AccelerationConfig) -> Void)?
    var onOpenConfigFile: (() -> Void)?
    var onRequestRestart: (() -> Void)?
    var onClose: (() -> Void)?

    // 表示
    private let secondsField = NSTextField()
    private let secondsStepper = NSStepper()
    private let positionPopup = NSPopUpButton()
    private let scaleField = NSTextField()
    private let scaleStepper = NSStepper()
    private let layerOffsetPopup = NSPopUpButton()
    private var toggles: [String: NSButton] = [:]

    // 加速
    private let accelEnabled = NSButton(checkboxWithTitle: "ポインタ加速を使う", target: nil, action: nil)
    private let accelOnlyBall = NSButton(checkboxWithTitle: "Nape Pro のときだけ効かせる（入力監視の許可が必要）",
                                         target: nil, action: nil)
    private let thresholdSlider = NSSlider()
    private let fullSpeedSlider = NSSlider()
    private let maxGainSlider = NSSlider()
    private let thresholdLabel = NSTextField(labelWithString: "")
    private let fullSpeedLabel = NSTextField(labelWithString: "")
    private let maxGainLabel = NSTextField(labelWithString: "")
    private let curveView = CurveView()
    private let accelNote = NSTextField(labelWithString: "")

    // レイヤー名
    private var layerNameFields: [Int: NSTextField] = [:]

    private let statusLabel = NSTextField(labelWithString: "")

    init(config: Config, configURL: URL) {
        self.config = config
        self.configURL = configURL
        super.init()
        buildWindow()
        load()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 組み立て

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "nape-hud 設定"
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 560, height: 420)

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(tab("表示", displayPane()))
        tabs.addTabViewItem(tab("ポインタ加速", accelerationPane()))
        tabs.addTabViewItem(tab("レイヤー名", layerNamePane()))

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let openFile = NSButton(title: "設定ファイルを開く", target: self, action: #selector(openFile))
        let save = NSButton(title: "保存", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let close = NSButton(title: "閉じる", target: self, action: #selector(closeWindow))

        let bar = NSStackView(views: [statusLabel, NSView(), openFile, close, save])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(tabs)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            bar.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        w.contentView = content
        window = w
        tabView = tabs
    }

    private func tab(_ title: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    /// 見出し + 中身を縦に積む共通の枠
    private func pane(_ rows: [NSView]) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView()
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: v.bottomAnchor),
        ])
        return v
    }

    private func row(_ label: String, _ controls: [NSView]) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.font = .systemFont(ofSize: 12)
        l.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let s = NSStackView(views: [l] + controls)
        s.orientation = .horizontal
        s.spacing = 8
        s.alignment = .centerY
        return s
    }

    private func note(_ text: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = 500
        return t
    }

    // MARK: - 表示タブ

    private func displayPane() -> NSView {
        secondsField.isEditable = false
        secondsField.isBordered = false
        secondsField.drawsBackground = false
        secondsField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        secondsStepper.minValue = 0.5
        secondsStepper.maxValue = 10
        secondsStepper.increment = 0.1
        secondsStepper.target = self
        secondsStepper.action = #selector(stepperChanged)

        for (title, value) in [("中央", "center"), ("上", "top"), ("左上", "topLeft"),
                               ("右上", "topRight"), ("下", "bottom"),
                               ("左下", "bottomLeft"), ("右下", "bottomRight")] {
            positionPopup.addItem(withTitle: title)
            positionPopup.lastItem?.representedObject = value
        }

        scaleField.isEditable = false
        scaleField.isBordered = false
        scaleField.drawsBackground = false
        scaleField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        scaleStepper.minValue = 0.5
        scaleStepper.maxValue = 3.0
        scaleStepper.increment = 0.1
        scaleStepper.target = self
        scaleStepper.action = #selector(stepperChanged)

        layerOffsetPopup.addItem(withTitle: "1〜8（状態通知どおり）")
        layerOffsetPopup.lastItem?.representedObject = 0
        layerOffsetPopup.addItem(withTitle: "0〜7（Keychron Launcher に合わせる）")
        layerOffsetPopup.lastItem?.representedObject = -1

        func check(_ key: String, _ title: String) -> NSButton {
            let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            toggles[key] = b
            return b
        }

        return pane([
            row("表示秒数", [secondsField, secondsStepper]),
            row("表示位置", [positionPopup]),
            row("拡大率", [scaleField, scaleStepper]),
            row("レイヤー番号", [layerOffsetPopup]),
            note("レイヤー番号はデバイスが 1〜8 で通知する。Launcher は同じものを 0〜7 と表示するので、揃えたい場合は下側を選ぶ。"),
            check("showConnection", "接続種別（USB-C / 2.4G / BT）を表示する"),
            check("showOnConnectionChange", "接続・切断のときも通知する"),
            check("showAngleDial", "角度ダイヤルを描く"),
            check("followsMouseScreen", "マウスカーソルのある画面に表示する"),
            check("showMenuBarIcon", "メニューバーに常駐する"),
            check("menuBarShowsLayer", "メニューバーに現在のレイヤー番号を添える"),
            note("メニューバー常駐を切ると終了操作ができなくなるので注意。"),
        ])
    }

    // MARK: - 加速タブ

    private func accelerationPane() -> NSView {
        accelEnabled.target = self
        accelEnabled.action = #selector(accelChanged)
        accelOnlyBall.target = self
        accelOnlyBall.action = #selector(accelChanged)

        func slider(_ s: NSSlider, _ lo: Double, _ hi: Double) -> NSSlider {
            s.minValue = lo
            s.maxValue = hi
            s.target = self
            s.action = #selector(accelChanged)
            s.isContinuous = true
            s.widthAnchor.constraint(equalToConstant: 220).isActive = true
            return s
        }
        _ = slider(thresholdSlider, 50, 1200)
        _ = slider(fullSpeedSlider, 600, 5000)
        _ = slider(maxGainSlider, 1.0, 6.0)
        for l in [thresholdLabel, fullSpeedLabel, maxGainLabel] {
            l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            l.widthAnchor.constraint(equalToConstant: 90).isActive = true
        }

        curveView.translatesAutoresizingMaskIntoConstraints = false
        curveView.widthAnchor.constraint(equalToConstant: 480).isActive = true
        curveView.heightAnchor.constraint(equalToConstant: 110).isActive = true

        accelNote.font = .systemFont(ofSize: 11)
        accelNote.textColor = .secondaryLabelColor

        return pane([
            accelEnabled,
            accelOnlyBall,
            note("小径トラックボール向けに、速く転がしたときだけ移動量を増やす。効き始めより遅いときは等倍のままなので、細かい操作の感触は保たれる。"),
            row("効き始め", [thresholdSlider, thresholdLabel]),
            row("最大になる速度", [fullSpeedSlider, fullSpeedLabel]),
            row("最大倍率", [maxGainSlider, maxGainLabel]),
            curveView,
            accelNote,
            note("⚠️ 有効にするとアクセシビリティの許可が必要。「Nape Pro のときだけ」には入力監視の許可も要る（許可しないと内蔵トラックパッドにも効いてしまうため、その場合は加速を止める）。"),
        ])
    }

    // MARK: - レイヤー名タブ

    private func layerNamePane() -> NSView {
        var rows: [NSView] = [note("ポップアップに出すレイヤーの呼び名。空欄なら「Layer N」と表示する。")]
        let offset = config.hud.layerNumberOffset
        let numbers = offset == -1 ? Array(0...7) : Array(1...8)
        for n in numbers {
            let f = NSTextField(string: "")
            f.placeholderString = "Layer \(n)"
            f.widthAnchor.constraint(equalToConstant: 260).isActive = true
            layerNameFields[n] = f
            rows.append(row("レイヤー \(n)", [f]))
        }
        return pane(rows)
    }

    // MARK: - 読み込み / 反映

    private func load() {
        let h = config.hud
        secondsStepper.doubleValue = h.seconds
        scaleStepper.doubleValue = h.scale
        syncSteppers()
        positionPopup.selectItem(at: positionPopup.itemArray.firstIndex {
            ($0.representedObject as? String)?.lowercased() == h.position.lowercased()
        } ?? 3)
        layerOffsetPopup.selectItem(at: h.layerNumberOffset == -1 ? 1 : 0)

        toggles["showConnection"]?.state = h.showConnection ? .on : .off
        toggles["showOnConnectionChange"]?.state = h.showOnConnectionChange ? .on : .off
        toggles["showAngleDial"]?.state = h.showAngleDial ? .on : .off
        toggles["followsMouseScreen"]?.state = h.followsMouseScreen ? .on : .off
        toggles["showMenuBarIcon"]?.state = h.showMenuBarIcon ? .on : .off
        toggles["menuBarShowsLayer"]?.state = h.menuBarShowsLayer ? .on : .off

        let a = config.acceleration
        accelEnabled.state = a.enabled ? .on : .off
        accelOnlyBall.state = a.onlyTrackball ? .on : .off
        thresholdSlider.doubleValue = a.thresholdSpeed
        fullSpeedSlider.doubleValue = a.fullSpeed
        maxGainSlider.doubleValue = a.maxGain
        syncAccelLabels()

        for (n, f) in layerNameFields {
            f.stringValue = config.layerNames[String(n)] ?? ""
        }
    }

    private func syncSteppers() {
        secondsField.stringValue = String(format: "%.1f 秒", secondsStepper.doubleValue)
        scaleField.stringValue = String(format: "%.1f 倍", scaleStepper.doubleValue)
    }

    @objc private func stepperChanged() { syncSteppers() }

    private func currentAcceleration() -> AccelerationConfig {
        var a = config.acceleration
        a.enabled = accelEnabled.state == .on
        a.onlyTrackball = accelOnlyBall.state == .on
        a.thresholdSpeed = thresholdSlider.doubleValue.rounded()
        a.fullSpeed = max(fullSpeedSlider.doubleValue.rounded(), a.thresholdSpeed + 100)
        a.maxGain = (maxGainSlider.doubleValue * 10).rounded() / 10
        return a
    }

    private func syncAccelLabels() {
        let a = currentAcceleration()
        thresholdLabel.stringValue = String(format: "%.0f px/s", a.thresholdSpeed)
        fullSpeedLabel.stringValue = String(format: "%.0f px/s", a.fullSpeed)
        maxGainLabel.stringValue = String(format: "%.1f 倍", a.maxGain)
        curveView.config = a
        curveView.needsDisplay = true
        accelNote.stringValue = a.enabled
            ? "変更はすぐ反映される。保存すると次回起動時も有効。"
            : "無効のあいだは権限も不要（今までどおりの動作）。"
    }

    @objc private func accelChanged() {
        syncAccelLabels()
        // 加速だけは即時反映する。動かして確かめるものなので。
        onAccelerationChanged?(currentAcceleration())
    }

    // MARK: - 保存

    @objc private func save() {
        let h = config.hud
        let a = currentAcceleration()
        let pos = (positionPopup.selectedItem?.representedObject as? String) ?? h.position
        let offset = (layerOffsetPopup.selectedItem?.representedObject as? Int) ?? 0

        func b(_ key: String) -> String { toggles[key]?.state == .on ? "true" : "false" }
        func num(_ v: Double) -> String {
            v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
        }

        var updates: [(path: [String], json: String)] = [
            (["hud", "seconds"], num(secondsStepper.doubleValue)),
            (["hud", "position"], "\"\(pos)\""),
            (["hud", "scale"], num(scaleStepper.doubleValue)),
            (["hud", "layerNumberOffset"], String(offset)),
            (["hud", "showConnection"], b("showConnection")),
            (["hud", "showOnConnectionChange"], b("showOnConnectionChange")),
            (["hud", "showAngleDial"], b("showAngleDial")),
            (["hud", "followsMouseScreen"], b("followsMouseScreen")),
            (["hud", "showMenuBarIcon"], b("showMenuBarIcon")),
            (["hud", "menuBarShowsLayer"], b("menuBarShowsLayer")),
            (["acceleration", "enabled"], a.enabled ? "true" : "false"),
            (["acceleration", "onlyTrackball"], a.onlyTrackball ? "true" : "false"),
            (["acceleration", "thresholdSpeed"], num(a.thresholdSpeed)),
            (["acceleration", "fullSpeed"], num(a.fullSpeed)),
            (["acceleration", "maxGain"], num(a.maxGain)),
        ]

        // レイヤー名はまとめて 1 つのオブジェクトとして書き換える
        var names: [String: String] = config.layerNames
        for (n, f) in layerNameFields {
            let v = f.stringValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty { names.removeValue(forKey: String(n)) } else { names[String(n)] = v }
        }
        let namesJSON = "{ " + names.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
            .map { "\"\($0)\": \(quoted(names[$0]!))" }
            .joined(separator: ", ") + " }"
        updates.append((["layerNames"], names.isEmpty ? "{}" : namesJSON))

        do {
            switch try ConfigWriter.setValues(updates, in: configURL) {
            case .written(let backup):
                statusLabel.stringValue = "保存しました（控え: \(backup.lastPathComponent)）"
                askRestart()
            case .targetNotFound:
                warn("設定ファイルの該当箇所が見つからず、保存できませんでした。",
                     "「設定ファイルを開く」から直接編集してください。ファイルは変更していません。")
            }
        } catch {
            warn("保存に失敗しました", error.localizedDescription)
        }
    }

    private func quoted(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            default: out.unicodeScalars.append(c)
            }
        }
        return "\"\(out)\""
    }

    private func askRestart() {
        let a = NSAlert()
        a.messageText = "保存しました"
        a.informativeText = """
            表示まわりの設定は起動時に読み込むため、反映するには再起動が必要です。
            （ポインタ加速の値はすでに反映されています）
            """
        a.addButton(withTitle: "再起動して反映")
        a.addButton(withTitle: "あとで")
        if a.runModal() == .alertFirstButtonReturn { onRequestRestart?() }
    }

    private func warn(_ title: String, _ body: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }

    @objc private func openFile() { onOpenConfigFile?() }
    @objc private func closeWindow() { window.performClose(nil) }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private var tabView: NSTabView?

    /// レイアウト検証用（selftest から使う）。
    /// タブの中身は親の fittingSize に出てこないので、タブごとに測る。
    var paneFits: [(label: String, needed: NSSize, available: NSSize)] {
        guard let c = window.contentView, let tabs = tabView else { return [] }
        c.layoutSubtreeIfNeeded()
        let available = tabs.contentRect.size
        return tabs.tabViewItems.compactMap { item in
            // 枠の NSView ではなく、実際に中身を持つスタックを測る
            guard let inner = item.view?.subviews.first else { return nil }
            inner.layoutSubtreeIfNeeded()
            return (item.label, inner.fittingSize, available)
        }
    }
}

// MARK: - 加速カーブの図

/// 速度に対する倍率の曲線を描く。数値だけだと効き方が想像しづらいため。
final class CurveView: NSView {
    var config = AccelerationConfig()

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds.insetBy(dx: 8, dy: 8)
        guard b.width > 20, b.height > 20 else { return }

        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        let frame = NSBezierPath(rect: b)
        frame.lineWidth = 1
        frame.stroke()

        let maxSpeed = max(config.fullSpeed * 1.3, 100)
        let maxG = max(config.maxGain, config.baseGain) + 0.3
        func pt(_ speed: Double, _ gain: Double) -> NSPoint {
            NSPoint(x: b.minX + b.width * min(speed / maxSpeed, 1),
                    y: b.minY + b.height * min(max((gain - 1) / max(maxG - 1, 0.1), 0), 1))
        }

        // 等倍の線
        let one = NSBezierPath()
        one.move(to: NSPoint(x: b.minX, y: pt(0, 1).y))
        one.line(to: NSPoint(x: b.maxX, y: pt(0, 1).y))
        one.lineWidth = 1
        NSColor.separatorColor.setStroke()
        one.stroke()

        // 曲線
        let curve = NSBezierPath()
        for i in 0...120 {
            let sp = maxSpeed * Double(i) / 120
            let g = PointerAccelerator.gain(forSpeed: sp, config: config)
            let p = pt(sp, g)
            if i == 0 { curve.move(to: p) } else { curve.line(to: p) }
        }
        curve.lineWidth = 2
        (config.enabled ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        curve.stroke()

        // 目盛り
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        ("等倍" as NSString).draw(at: NSPoint(x: b.minX + 3, y: pt(0, 1).y + 1), withAttributes: attrs)
        (String(format: "%.1f倍", config.maxGain) as NSString)
            .draw(at: NSPoint(x: b.maxX - 34, y: pt(0, config.maxGain).y - 12), withAttributes: attrs)
        (String(format: "%.0f px/s", maxSpeed) as NSString)
            .draw(at: NSPoint(x: b.maxX - 52, y: b.minY + 2), withAttributes: attrs)
        ("速度 →" as NSString).draw(at: NSPoint(x: b.minX + 3, y: b.minY + 2), withAttributes: attrs)
    }
}
