import AppKit

/// ポインタ加速（任意機能）。
///
/// 小径トラックボールは 1 スワイプで稼げる移動量が小さいので、速く転がしたときだけ
/// 移動量を増幅する。ファームウェアではなくホスト側で行う。
///
/// ## デバイスの判別について
/// カーソル移動イベントには発生元のデバイスを示す値が無い。
/// 実機で確認したところ、senderID と言われるフィールド 87 はトラックボールでも
/// 内蔵トラックパッドでも同じ値（54240）で、これでは判別できなかった。
/// そのため「Nape Pro の HID 入力が直前にあったか」を別途監視して判定する
/// （`isTrackballActive` に外から渡す）。
final class PointerAccelerator {
    private let config: AccelerationConfig
    private var tap: CFMachPort?

    /// 直前に Nape Pro が動いていたか。onlyTrackball のときだけ参照する。
    var isTrackballActive: () -> Bool = { true }
    /// 現在のレイヤー（perLayerGain の引き当て用）
    var currentLayer: () -> Int? = { nil }

    /// 速度の平滑化値 (px/秒)。1kHz の生の差分は暴れるので指数移動平均で均す。
    private var smoothedSpeed: Double = 0
    private var lastTime: CFAbsoluteTime = 0
    /// 整数化で切り捨てた端数。持ち越さないと遅い動きで移動量が失われる。
    private var carryX: Double = 0
    private var carryY: Double = 0

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

    // MARK: -

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 処理が重いとタップが無効化されることがあるので復帰させる
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard isEnabled else { return Unmanaged.passUnretained(event) }

        let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
        let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
        guard dx != 0 || dy != 0 else { return Unmanaged.passUnretained(event) }

        // Nape Pro 由来でなければ素通し（内蔵トラックパッドに効かせない）
        if config.onlyTrackball, !isTrackballActive() {
            resetSmoothing()
            return Unmanaged.passUnretained(event)
        }

        let gain = gainFor(dx: dx, dy: dy)
        guard abs(gain - 1.0) > 0.001 else { return Unmanaged.passUnretained(event) }

        // 端数を持ち越して整数化する
        let wantX = dx * gain + carryX
        let wantY = dy * gain + carryY
        var outX = (wantX).rounded(.towardZero)
        var outY = (wantY).rounded(.towardZero)
        carryX = wantX - outX
        carryY = wantY - outY

        // 暴れ防止
        let cap = config.maxDeltaPerEvent
        if cap > 0 {
            outX = min(max(outX, -cap), cap)
            outY = min(max(outY, -cap), cap)
        }

        // 差分だけ書き換えてもカーソルは動かない。位置も入れ替える必要がある。
        // 元イベントの位置から素の差分を引けば「1 つ前の位置」が得られる。
        let loc = event.location
        let prev = CGPoint(x: loc.x - dx, y: loc.y - dy)
        let moved = CGPoint(x: prev.x + outX, y: prev.y + outY)

        event.location = clampToScreens(moved)
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(outX))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(outY))
        return Unmanaged.passUnretained(event)
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

    private func gainFor(dx: Double, dy: Double) -> Double {
        let now = CFAbsoluteTimeGetCurrent()
        var dt = now - lastTime
        lastTime = now
        // 初回や間が空いたときに巨大な速度と誤認しないよう幅を制限する
        if dt <= 0 || dt > 0.05 { dt = 0.05 }
        dt = max(dt, 0.001)

        let instant = (dx * dx + dy * dy).squareRoot() / dt
        // 1kHz の生値は暴れるので均す
        smoothedSpeed += (instant - smoothedSpeed) * 0.35

        // レイヤーごとの上書き（そのレイヤーでの最大倍率として扱う）
        let layerMax = currentLayer().flatMap { config.perLayerGain[String($0)] }
        return Self.gain(forSpeed: smoothedSpeed, config: config, layerMaxGain: layerMax)
    }

    private func resetSmoothing() {
        smoothedSpeed = 0
        carryX = 0
        carryY = 0
        lastTime = 0
    }

    /// 画面の外に飛ばさない
    private func clampToScreens(_ p: CGPoint) -> CGPoint {
        guard let first = NSScreen.screens.first else { return p }
        var union = first.frame
        for s in NSScreen.screens.dropFirst() { union = union.union(s.frame) }
        // CGEvent の座標系は上下が反転しているので、高さから引いて合わせる
        let maxY = NSScreen.screens.map(\.frame.maxY).max() ?? union.maxY
        let flipped = NSRect(x: union.minX, y: maxY - union.maxY,
                             width: union.width, height: union.height)
        return CGPoint(x: min(max(p.x, flipped.minX), flipped.maxX - 1),
                       y: min(max(p.y, flipped.minY), flipped.maxY - 1))
    }
}
