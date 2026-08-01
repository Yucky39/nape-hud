import AppKit

/// ポインタ加速（任意機能）。
///
/// 小径トラックボールは 1 スワイプで稼げる移動量が小さいので、速く転がしたときだけ
/// 移動量を増幅する。ファームウェアではなくホスト側で行う。
///
/// ## どうやって移動量を増やすか
/// **イベントの delta や location を書き換えてもカーソルは動かない。** 実機で確認した:
///   - セッション層のタップで location を書き換え → 実効 1.07 倍（反映率 16%）
///   - HID 層のタップで delta を書き換え         → 実効 1.00 倍
/// macOS はカーソル位置を下層の IOHIDEvent から決めており、CGEvent 側の値は
/// 「アプリに届く座標」でしかない。書き換えると経路がジグザグになり、
/// シェイク検出が働いてカーソルが拡大するだけだった。
///
/// 効いたのは **元イベントを破棄して、増幅した合成イベントを流し直す**方式（実効 3.01 倍）。
/// 合成イベントの位置は window server がそのまま採用するため、確実にカーソルが動く。
///
/// ## デバイスの判別について
/// カーソル移動イベントには発生元のデバイスを示す値が無い。
/// 実機で確認したところ、senderID と言われるフィールド 87 はトラックボールでも
/// 内蔵トラックパッドでも同じ値（54240）で、これでは判別できなかった。
/// そのため「Nape Pro の HID 入力が直前にあったか」を別途監視して判定する
/// （`isTrackballActive` に外から渡す）。
final class PointerAccelerator {
    /// 設定画面から動かしながら調整できるよう可変にしてある
    private(set) var config: AccelerationConfig
    private var tap: CFMachPort?

    /// 直前に Nape Pro が動いていたか。onlyTrackball のときだけ参照する。
    var isTrackballActive: () -> Bool = { true }
    /// 現在のレイヤー（perLayerGain の引き当て用）
    var currentLayer: () -> Int? = { nil }

    /// 速度の平滑化値 (px/秒)。1kHz の生の差分は暴れるので指数移動平均で均す。
    private var smoothedSpeed: Double = 0
    /// 実際に適用している倍率。目標値へ一定の速さで近づける（急に上がると見失う）。
    private var appliedGain: Double = 1
    /// 直近に適用した画面調整係数（--debug 表示用）
    private var lastDisplayScale: Double = 1
    private var lastTime: CFAbsoluteTime = 0
    /// 整数化で切り捨てた端数。持ち越さないと遅い動きで移動量が失われる。
    private var carryX: Double = 0
    private var carryY: Double = 0

    /// 自分が流し直したイベントの目印。これが無いと自分のイベントを無限に増幅してしまう。
    static let marker: Int64 = 0x4E415045      // 'NAPE'

    /// --debug のときだけ実効倍率を集計して出す。
    /// 素通しした分も母数に入れないと「最大倍率」と比べられる数字にならない。
    var debug = false
    private var rawTravel = 0.0        // 元の移動量（素通し分も含む）
    private var outTravel = 0.0        // 実際の移動量（素通し分も含む）
    private var seen = 0               // 対象となったイベント数
    private var amplified = 0          // うち増幅したもの
    private var gainSum = 0.0          // 増幅したものの倍率の合計
    private var peakSpeed = 0.0

    init(config: AccelerationConfig) {
        self.config = config
    }

    func start() throws {
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDragged.rawValue)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // 書き換えるので listenOnly では駄目
            eventsOfInterest: mask,
            callback: { _, type, event, ctx in
                guard let ctx else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<PointerAccelerator>.fromOpaque(ctx).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: ctx
        ) else {
            throw Err("""
                ポインタ加速を開始できませんでした。
                システム設定 → プライバシーとセキュリティ → アクセシビリティ で
                NapeHUD を許可してください。
                """)
        }

        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    /// 実行中に切り替えられるようにしておく（効き具合を試すため）
    var isEnabled = true {
        didSet { if let tap { CGEvent.tapEnable(tap: tap, enable: isEnabled) } }
    }

    /// 設定画面での変更を即座に効かせる。
    /// カーブは動かして確かめるものなので、再起動を待たせない。
    func update(_ newConfig: AccelerationConfig) {
        config = newConfig
        isEnabled = newConfig.enabled
        resetSmoothing()
    }

    // MARK: -

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 処理が重いとタップが無効化されることがあるので復帰させる
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard isEnabled else { return Unmanaged.passUnretained(event) }

        // 自分が流し直したものは素通し（無限再帰の防止）
        guard event.getIntegerValueField(.eventSourceUserData) != Self.marker else {
            return Unmanaged.passUnretained(event)
        }

        let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
        let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
        guard dx != 0 || dy != 0 else { return Unmanaged.passUnretained(event) }

        // Nape Pro 由来でなければ素通し（内蔵トラックパッドに効かせない）
        if config.onlyTrackball, !isTrackballActive() {
            resetSmoothing()
            return Unmanaged.passUnretained(event)
        }

        let gain = gainFor(dx: dx, dy: dy, at: event.location)
        if debug {
            seen += 1
            rawTravel += abs(dx) + abs(dy)
            outTravel += abs(dx) + abs(dy)     // 増幅した分は後で足す
            peakSpeed = max(peakSpeed, smoothedSpeed)
        }
        guard abs(gain - 1.0) > 0.001 else {
            if debug { reportIfNeeded() }
            return Unmanaged.passUnretained(event)
        }

        // 追加で動かす量。端数を持ち越さないと遅い動きで移動量が失われる。
        let wantX = dx * (gain - 1) + carryX
        let wantY = dy * (gain - 1) + carryY
        var extraX = wantX.rounded(.towardZero)
        var extraY = wantY.rounded(.towardZero)
        carryX = wantX - extraX
        carryY = wantY - extraY

        // 暴れ防止
        let cap = config.maxDeltaPerEvent
        if cap > 0 {
            extraX = min(max(extraX, -cap), cap)
            extraY = min(max(extraY, -cap), cap)
        }
        guard extraX != 0 || extraY != 0 else { return Unmanaged.passUnretained(event) }

        // 元イベントを捨てて、増幅した合成イベントを流し直す。
        // （書き換えではカーソルが動かないことを実測で確認済み。冒頭のコメント参照）
        //
        // 基準は「そのイベント自身の位置」を使う。CGEvent(source:) で現在位置を読むと、
        // 直前に流した合成イベントがまだ反映されていない古い値を拾うことがあり、
        // 増幅量が過剰・過少になってカーソルが暴れる。
        let target = CGPoint(x: event.location.x + extraX, y: event.location.y + extraY)
        // どの画面にも属さない座標へ送ると system が引き戻して跳ぶので、その場合は増幅しない
        guard let moved = validPosition(target) else {
            return Unmanaged.passUnretained(event)
        }

        let button = CGMouseButton(rawValue: UInt32(event.getIntegerValueField(.mouseEventButtonNumber)))
            ?? .left
        guard let synth = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: moved, mouseButton: button) else {
            return Unmanaged.passUnretained(event)
        }
        synth.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx + extraX))
        synth.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy + extraY))
        synth.setIntegerValueField(.mouseEventButtonNumber,
                                   value: event.getIntegerValueField(.mouseEventButtonNumber))
        synth.flags = event.flags
        synth.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        synth.post(tap: .cghidEventTap)

        if debug {
            outTravel += abs(extraX) + abs(extraY)
            amplified += 1
            gainSum += gain
            reportIfNeeded()
        }
        return nil      // 元イベントは破棄
    }

    /// 集計結果を定期的に出す。
    /// 「実効倍率」は素通し分も母数に入れた全体平均なので、最大倍率より必ず低くなる。
    private func reportIfNeeded() {
        guard seen > 0, seen % 400 == 0 else { return }
        let overall = outTravel / max(rawTravel, 1)
        let avgWhenAmplified = amplified > 0 ? gainSum / Double(amplified) : 1
        let share = Int(Double(amplified) / Double(seen) * 100)
        let l1 = String(format: "加速: %d 件（増幅 %d%%）/ 元 %.0f px \u{2192} %.0f px\n",
                        seen, share, rawTravel, outTravel)
        let l2 = String(format: "     実効倍率 %.2fx（全体平均）  増幅時の平均 %.2fx  設定上限 %.2fx\n",
                        overall, avgWhenAmplified, config.maxGain)
        let l3 = String(format: "     到達した最高速度 %.0f px/s（上限に達するのは %.0f px/s 以上）\n",
                        peakSpeed, config.fullSpeed)
        let l4 = config.displayScaling.enabled
            ? String(format: "     画面調整 %.2fx（実効上限 %.2fx）\n",
                     lastDisplayScale,
                     config.baseGain + (config.maxGain - config.baseGain) * lastDisplayScale)
            : ""
        FileHandle.standardError.write((l1 + l2 + l3 + l4).data(using: .utf8)!)
    }

    /// 速度 (px/秒) → 倍率。しきい値未満は素のまま、fullSpeed 以上で maxGain。
    /// 境界で急に変わると気持ち悪いので smoothstep でつなぐ。
    /// 検証しやすいよう副作用のない関数として切り出してある。
    static func gain(forSpeed speed: Double, config c: AccelerationConfig,
                     layerMaxGain: Double? = nil) -> Double {
        let lo = c.thresholdSpeed
        let hi = max(c.fullSpeed, lo + 1)
        var t = (speed - lo) / (hi - lo)
        t = min(max(t, 0), 1)
        let s = t * t * (3 - 2 * t)          // smoothstep
        let top = layerMaxGain ?? c.maxGain
        return c.baseGain + (top - c.baseGain) * s
    }

    private func gainFor(dx: Double, dy: Double, at point: CGPoint) -> Double {
        let now = CFAbsoluteTimeGetCurrent()
        var dt = now - lastTime
        lastTime = now
        // 初回や間が空いたときに巨大な速度と誤認しないよう幅を制限する
        if dt <= 0 || dt > 0.05 { dt = 0.05 }
        dt = max(dt, 0.001)

        let instant = (dx * dx + dy * dy).squareRoot() / dt
        // 1kHz の生値は暴れるので均す。係数が小さいほど滑らか。
        let k = min(max(config.smoothing, 0.01), 1.0)
        smoothedSpeed += (instant - smoothedSpeed) * k

        // レイヤーごとの上書き（そのレイヤーでの最大倍率として扱う）
        let layerMax = currentLayer().flatMap { config.perLayerGain[String($0)] }
        // 画面の大きさに応じて上限を調整する（有効時のみ）
        let scale = Self.displayScale(at: point, config: config.displayScaling)
        lastDisplayScale = scale
        let top = (layerMax ?? config.maxGain)
        let scaledTop = config.baseGain + (top - config.baseGain) * scale
        let target = Self.gain(forSpeed: smoothedSpeed, config: config, layerMaxGain: scaledTop)

        // 目標倍率へ一気に飛ばさず、1 秒あたりの変化量を制限して近づける。
        // これが無いと「動かし始めた瞬間に最高倍率」になってカーソルを見失う。
        // 下げる側は速く戻したほうが扱いやすいので係数を掛ける。
        let up = max(config.rampPerSecond, 0.1)
        let limit = (target > appliedGain ? up : up * max(config.rampDownFactor, 1)) * dt
        let diff = target - appliedGain
        appliedGain += abs(diff) <= limit ? diff : (diff > 0 ? limit : -limit)
        let ceiling = max(config.baseGain + (config.maxGain - config.baseGain)
                          * max(config.displayScaling.maxScale, 1), 1)
        appliedGain = min(max(appliedGain, min(config.baseGain, 1)), ceiling)
        return appliedGain
    }

    private func resetSmoothing() {
        smoothedSpeed = 0
        appliedGain = 1
        carryX = 0
        carryY = 0
        lastTime = 0
    }


    // MARK: - 画面サイズに応じた調整

    /// 画面の論理サイズから求めた倍率の調整係数。
    ///
    /// カーソルは論理座標（ポイント）で動くので、画面を横断するのに必要な移動量は
    /// 論理サイズに比例する。実機の 2 画面では対角比が 1.26 と 0.69 で 2 倍近く違い、
    /// 同じ倍率だと片方で足りず片方で行き過ぎる。
    /// 物理サイズや PPI ではなく論理サイズを使うのが正しい（Retina でも
    /// カーソルの移動量はポイント基準で決まるため）。
    static func displayScale(at point: CGPoint, config c: DisplayScalingConfig) -> Double {
        guard c.enabled else { return 1 }
        guard let target = displayBounds.first(where: { $0.contains(point) }) ?? displayBounds.first
        else { return 1 }

        func size(_ r: CGRect) -> Double {
            c.metric.lowercased() == "width"
                ? r.width
                : (r.width * r.width + r.height * r.height).squareRoot()
        }
        // 基準サイズ。0 なら主画面（= 設定値は主画面での倍率という意味になる）
        let reference: Double
        if c.referenceSize > 0 {
            reference = c.referenceSize
        } else if let main = displayBounds.first(where: { $0.origin == .zero }) {
            reference = size(main)
        } else {
            reference = size(target)
        }
        guard reference > 0 else { return 1 }
        let raw = size(target) / reference
        return min(max(raw, min(c.minScale, 1)), max(c.maxScale, 1))
    }

    /// 検証・表示用。各画面の名前と調整係数を返す。
    static func displayScaleSummary(config c: DisplayScalingConfig) -> [(name: String, size: String, scale: Double)] {
        displayBounds.map { r in
            let name = NSScreen.screens.first { s in
                s.frame.width == r.width && s.frame.height == r.height
            }?.localizedName ?? "画面"
            return (name, "\(Int(r.width))×\(Int(r.height)) pt",
                    displayScale(at: CGPoint(x: r.midX, y: r.midY), config: c))
        }
    }

    /// 送り先が実在する画面の上かを確かめる。
    ///
    /// 画面の外接矩形（union）でクランプする実装だと、大きさの違う画面を並べたときに
    /// 「union の内側だがどの画面にも属さない」領域が生まれる。実機の 2 画面構成では
    /// union の 7% がそれに当たり、そこへ送ると system がカーソルを引き戻して跳ねていた。
    /// そのため矩形で丸めるのではなく、有効かどうかで判定する。
    private func validPosition(_ p: CGPoint) -> CGPoint? {
        for r in Self.displayBounds where r.contains(p) { return p }
        return nil
    }

    /// 画面構成は頻繁には変わらないので、変更通知で作り直す方式にして毎回の問い合わせを避ける
    private static var cachedBounds: [CGRect] = []
    private static var boundsObserver: NSObjectProtocol?
    static var displayBounds: [CGRect] {
        if boundsObserver == nil {
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { _ in cachedBounds = [] }
        }
        if cachedBounds.isEmpty {
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            var n: UInt32 = 0
            CGGetActiveDisplayList(16, &ids, &n)
            cachedBounds = (0..<Int(n)).map { CGDisplayBounds(ids[$0]) }
        }
        return cachedBounds
    }
}

/// 加速の適用結果。設定画面にそのまま出せる文言と、足りない許可を持つ。
struct AccelerationStatus {
    enum Permission { case accessibility, inputMonitoring }
    var running: Bool
    var message: String
    var permission: Permission?
}
