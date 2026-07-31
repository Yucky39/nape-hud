import AppKit

/// アプリ内で向きの校正を行うウインドウ。
///
/// CLI の `calibrate` と同じ手順（基準の向きから 8 方向切替ボタンを 1 周押す）を
/// 案内しつつ、CLI では手作業だった **設定ファイルへの反映まで** 行う。
///
/// 校正中は通常のポップアップを止める（ボタンを押すたびに HUD が出ると邪魔なので）。
final class CalibrationController: NSObject, NSWindowDelegate {
    private let calibrator: Calibrator
    private let configURL: URL
    private var window: NSWindow!

    private let statusLabel = NSTextField(labelWithString: "")
    private let listLabel = NSTextField(labelWithString: "")
    private let resultField = NSTextField(labelWithString: "")
    private let zeroLabel = NSTextField(labelWithString: "")
    private var saveButton: NSButton!
    private var copyButton: NSButton!
    private var rotateLeft: NSButton!
    private var rotateRight: NSButton!
    private var zeroPicker: NSPopUpButton!
    private var finished = false

    /// 校正が終わって（保存またはキャンセルで）閉じたときに呼ばれる。
    /// Bool は「設定を書き換えたので再起動が必要か」。
    var onClose: ((Bool) -> Void)?

    init(rules: [Rule], settings: CalibrationConfig, configURL: URL) {
        self.calibrator = Calibrator(rules: rules, settings: settings)
        self.configURL = configURL
        super.init()
        calibrator.quiet = true
        buildWindow()
        calibrator.onDetected = { [weak self] n, code, layer in
            self?.detected(n, code, layer)
        }
        calibrator.onCycleComplete = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.finish(cycled: true) }
        }
    }

    var hasAngleRule: Bool { calibrator.hasAngleRule }

    /// レイアウト検証用。内容の必要サイズと実際のウインドウ内寸を返す。
    /// （必要サイズが内寸を超えていると、ボタン列などが見えなくなる）
    var layoutFit: (needed: NSSize, actual: NSSize) {
        guard let content = window.contentView else { return (.zero, .zero) }
        content.layoutSubtreeIfNeeded()
        return (content.fittingSize, content.frame.size)
    }

    /// 検証用に検出を注入する
    func injectForTesting(_ ev: ReportEvent) { calibrator.ingest(ev); refresh() }

    /// 校正中は true。呼び出し側はこの間 HUD を出さない。
    private(set) var isActive = false

    func begin() {
        isActive = true
        NSApp.activate(ignoringOtherApps: true)
        updateStatus()
        resizeToFit()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func ingest(_ ev: ReportEvent) {
        guard isActive, !finished else { return }
        calibrator.ingest(ev)
    }

    // MARK: - 画面

    /// 折り返しラベルの基準幅。ウインドウ幅の変更に追従させる。
    private let baseWidth: CGFloat = 500
    private var wrappingLabels: [NSTextField] = []

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: baseWidth, height: 360),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "向きの校正"
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.minSize = NSSize(width: baseWidth, height: 260)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "8 方向切替ボタンを 1 周ぶん押してください")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        let howto = NSTextField(wrappingLabelWithString: """
            1. Keychron Launcher を閉じてください（開いていると通信が混ざります）
            2. どの向きから始めても構いません
            3. 8 方向切替ボタンを 8 回押して 1 周させます（揃うと自動で完了）

            0° にする向きは下のメニューから選べます（◀ ▶ で 1 つずつずらすこともできます）。
            設定 calibration.angleZeroCode に書いておけば毎回それが初期値になります。
            """)
        howto.font = .systemFont(ofSize: 12)
        howto.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        listLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        listLabel.textColor = .secondaryLabelColor
        listLabel.lineBreakMode = .byWordWrapping
        listLabel.maximumNumberOfLines = 0   // 行数で切らない。ウインドウ側を伸ばす

        resultField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        resultField.isSelectable = true
        resultField.lineBreakMode = .byWordWrapping
        resultField.maximumNumberOfLines = 0

        // 0° の基準を選ぶ。検出済みの向きから直接選べるようにして、
        // 「0° にしたい向きから始める」制約を外す。
        let zeroRow = NSStackView()
        zeroRow.orientation = .horizontal
        zeroRow.spacing = 8
        zeroPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        zeroPicker.target = self
        zeroPicker.action = #selector(pickZero)
        zeroPicker.isEnabled = false
        rotateLeft = NSButton(title: "◀", target: self, action: #selector(rotate(_:)))
        rotateRight = NSButton(title: "▶", target: self, action: #selector(rotate(_:)))
        rotateLeft.isEnabled = false
        rotateRight.isEnabled = false
        zeroLabel.font = .systemFont(ofSize: 11)
        zeroLabel.textColor = .secondaryLabelColor
        let zeroCaption = NSTextField(labelWithString: "0° にする向き:")
        zeroCaption.font = .systemFont(ofSize: 12)
        zeroCaption.textColor = .secondaryLabelColor
        [zeroCaption, zeroPicker, rotateLeft, rotateRight, zeroLabel]
            .forEach { zeroRow.addView($0, in: .leading) }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10

        saveButton = NSButton(title: "設定に保存", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.isEnabled = false
        copyButton = NSButton(title: "JSON をコピー", target: self, action: #selector(copyJSON))
        copyButton.isEnabled = false
        let cancel = NSButton(title: "キャンセル", target: self, action: #selector(cancel))
        let done = NSButton(title: "ここまでで確定", target: self, action: #selector(finishNow))

        [saveButton, copyButton, done, cancel].forEach { buttons.addView($0, in: .leading) }

        [heading, howto, statusLabel, listLabel, zeroRow, resultField, buttons].forEach {
            stack.addView($0, in: .top)
        }

        // 折り返すラベルは幅を明示しないと高さが決まらない
        wrappingLabels = [howto, listLabel, resultField]
        wrappingLabels.forEach { $0.preferredMaxLayoutWidth = baseWidth - 40 }

        let content = NSView()
        content.addSubview(stack)
        // 4 辺すべてを留める。下端を留めないと内容の高さがウインドウに伝わらず、
        // ボタン列がはみ出して見えなくなる。
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        w.contentView = content
        window = w
        resizeToFit()
    }

    /// 内容の実寸にウインドウを合わせる。検出が増えて行数が伸びても切れないようにする。
    private func resizeToFit() {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        let target = NSSize(width: max(fitting.width, content.frame.width, baseWidth),
                            height: max(fitting.height, 1))
        guard abs(target.height - content.frame.height) > 0.5
                || target.width > content.frame.width + 0.5 else { return }

        // setContentSize は左下を固定するため、そのままだとタイトルバーが動く。
        // 上端を固定して下に伸ばす。
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(target)
        var f = window.frame
        f.origin = NSPoint(x: topLeft.x, y: topLeft.y - f.height)
        window.setFrame(f, display: true)
    }

    private func detected(_ n: Int, _ code: Int, _ layer: Int?) {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// 一覧・状態・ボタンの活性を現在の割り当てに合わせる
    private func refresh() {
        let codes = calibrator.codes
        listLabel.stringValue = codes.enumerated().map { i, c in
            String(format: "#%d 0x%02X → %d°", i + 1, c, calibrator.degrees(forIndex: i))
        }.joined(separator: "   ")

        updateStatus()
        resultField.stringValue = "\"map\": \(calibrator.mapJSON())"

        // 0° 候補の一覧を作り直す（現在の 0° を選択状態にする）
        zeroPicker.removeAllItems()
        for (i, c) in codes.enumerated() {
            zeroPicker.addItem(withTitle: String(format: "#%d  0x%02X", i + 1, c))
        }
        if !codes.isEmpty { zeroPicker.selectItem(at: calibrator.zeroIndex) }

        let ready = codes.count >= 2
        saveButton.isEnabled = ready
        copyButton.isEnabled = ready
        rotateLeft.isEnabled = ready
        rotateRight.isEnabled = ready
        zeroPicker.isEnabled = ready

        // 検出が増えて一覧が折り返すと高さが変わるので、そのたびに合わせる
        resizeToFit()
    }

    @objc private func pickZero() {
        let i = zeroPicker.indexOfSelectedItem
        guard i >= 0, i < calibrator.codes.count else { return }
        calibrator.chosenZeroCode = calibrator.codes[i]
        calibrator.rotation = 0
        refresh()
    }

    private func updateStatus() {
        let n = calibrator.codes.count
        guard n > 0 else {
            statusLabel.stringValue = "待機中… ボタンを押してください"
            zeroLabel.stringValue = ""
            return
        }
        statusLabel.stringValue = "検出 \(n) 方向"
            + (calibrator.completedCycle ? "（1 周ぶん揃いました）" : "（\(calibrator.expectedPositions) 方向まで押してください）")
        zeroLabel.stringValue = "基準: \(calibrator.zeroSourceNote)"
    }

    /// 0° の基準を一覧の前後へ 1 つ動かす。
    @objc private func rotate(_ sender: NSButton) {
        calibrator.rotation += (sender === rotateLeft ? -1 : 1)
        refresh()
    }

    // MARK: - 完了処理

    /// 割り当ては「検出数で 360° を割る」ため、1 周し終える前に確定すると刻み幅がずれる。
    /// そのため確定時に検出数を明示する。
    private func finish(cycled: Bool) {
        guard !finished else { return }
        finished = true
        let n = calibrator.codes.count
        resultField.isHidden = false
        refresh()
        statusLabel.stringValue = cycled
            ? "1 周ぶん揃いました（\(n) 方向 / \(calibrator.step)° 刻み）。設定に保存できます。"
            : "\(n) 方向で確定しました（\(calibrator.step)° 刻み）"
        if n >= 2 { window.makeFirstResponder(saveButton) }
    }

    @objc private func finishNow() { finish(cycled: calibrator.completedCycle) }

    @objc private func copyJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(calibrator.mapJSON(), forType: .string)
        statusLabel.stringValue = "クリップボードにコピーしました"
    }

    @objc private func save() {
        if !finished { finish(cycled: calibrator.completedCycle) }
        guard calibrator.codes.count >= 2 else { return }

        do {
            switch try ConfigWriter.updateAngleMap(calibrator.mapJSON(), in: configURL) {
            case .written(let backup):
                let a = NSAlert()
                a.messageText = "設定を更新しました"
                a.informativeText = """
                    \(configURL.path) の angle.map を書き換えました。
                    元のファイルは次の場所に控えてあります:
                    \(backup.lastPathComponent)

                    反映するには再起動が必要です。
                    """
                a.addButton(withTitle: "再起動して反映")
                a.addButton(withTitle: "あとで")
                let restart = a.runModal() == .alertFirstButtonReturn
                close(needsRestart: restart)

            case .targetNotFound:
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = "設定ファイルを自動更新できませんでした"
                a.informativeText = """
                    rules[].angle の位置を特定できなかったため、ファイルは変更していません。
                    下の JSON を手で貼り付けてください（「JSON をコピー」で取得できます）。

                    \(calibrator.mapJSON())
                    """
                a.runModal()
            }
        } catch {
            let a = NSAlert(error: error)
            a.messageText = "設定ファイルの書き込みに失敗しました"
            a.runModal()
        }
    }

    @objc private func cancel() { close(needsRestart: false) }

    private func close(needsRestart: Bool) {
        isActive = false
        window.orderOut(nil)
        onClose?(needsRestart)
    }

    /// 手動リサイズに折り返し幅を追従させる（ここでは resizeToFit を呼ばない。呼ぶと発振する）
    func windowDidResize(_ notification: Notification) {
        guard let content = window.contentView else { return }
        let w = max(content.frame.width - 40, 200)
        wrappingLabels.forEach { $0.preferredMaxLayoutWidth = w }
        content.layoutSubtreeIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        guard isActive else { return }
        isActive = false
        onClose?(false)
    }
}
