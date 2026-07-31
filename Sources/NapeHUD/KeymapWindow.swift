import AppKit

/// キーアサインを別画面で表示する。
///
/// 中身は CLI の `nape-hud keymap` と同一の文字列を等幅で流し込む方式。
/// 表を AppKit の表ビューで組むより崩れにくく、選択してコピーできる。
final class KeymapController: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "読み出し中…")
    private var reloadButton: NSButton!
    private var copyButton: NSButton!

    private let match: DeviceMatch
    private let settings: KeymapConfig
    private let layerName: (Int) -> String
    var onClose: (() -> Void)?

    init(match: DeviceMatch, settings: KeymapConfig, layerName: @escaping (Int) -> String) {
        self.match = match
        self.settings = settings
        self.layerName = layerName
        super.init()
        buildWindow()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        reload()
    }

    // MARK: - 画面

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 560),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "キーアサイン"
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 560, height: 320)

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        // 折り返さず横スクロールさせる（表の桁が崩れないように）
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        reloadButton = NSButton(title: "再読み込み", target: self, action: #selector(reload))
        copyButton = NSButton(title: "コピー", target: self, action: #selector(copyAll))
        copyButton.isEnabled = false

        let bar = NSStackView(views: [statusLabel, NSView(), copyButton, reloadButton])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        w.contentView = content
        window = w
    }

    // MARK: - 読み出し

    @objc private func reload() {
        statusLabel.stringValue = "読み出し中…"
        reloadButton.isEnabled = false
        copyButton.isEnabled = false
        textView.string = ""

        VIAClient.readSnapshot(match: match, settings: settings) { [weak self] result in
            guard let self else { return }
            self.reloadButton.isEnabled = true
            switch result {
            case .success(let snap):
                self.textView.string = KeymapReport.text(snap, layerName: self.layerName)
                self.textView.sizeToFit()
                self.statusLabel.stringValue =
                    "レイヤー \(snap.layerCount) / 1 レイヤー \(snap.keysPerLayer) キー"
                self.copyButton.isEnabled = true
            case .failure(let error):
                self.textView.string = error.localizedDescription
                self.statusLabel.stringValue = "読み出しに失敗しました"
            }
        }
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        statusLabel.stringValue = "クリップボードにコピーしました"
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
