import Foundation

/// デバイスが返す生値（`code`）と、対応表を通した表示値（`value`）の対。
///
/// 対応表に無い生値でも `code` は保持する。黙って捨てると
/// 「ボタンを押したのに何も出ない」になって原因が分からなくなるため。
struct CodedValue: Equatable {
    var code: Int
    var value: Int?
    var isKnown: Bool { value != nil }
}

struct DeviceState: Equatable {
    var layer: Int?
    var angle: CodedValue?
    var dpi: CodedValue?
    /// バッテリー残量（％）。ボタン操作とは無関係に自発的に届くので、
    /// 主役表示のトリガーにはせず、届いた時点で静かに更新するだけにする。
    var battery: CodedValue?
}

/// 何を主役に表示するか。
///
/// 実測（フェーズ分離した learn）で分かった非対称性:
///   - レイヤー切替ボタン … レイヤー（offset 1）が動く。加えて「そのレイヤーに記憶された向き」も
///                          載るため向きフィールドまで変化することがある。
///   - 8 方向切替ボタン   … 向き（offset 2）だけが動く。レイヤーは動かない。
///   - DPI 切替ボタン     … DPI（offset 3）だけが動く。レイヤー・向きは動かない。
///
/// したがって判定は「レイヤー → 向き → DPI」の順でなければならない。
/// 逆順にすると、レイヤー切替時にレイヤー表示が角度表示に奪われる。
enum StateChange {
    case layerPrimary(Int)
    case anglePrimary(CodedValue)
    case dpiPrimary(CodedValue)
    /// 値は変わっていないがボタンは押された（notify: always のとき）。直前の表示を出し直す。
    case repeatLast
}

/// 生レポート → 状態変化。ルールに一致しないレポートは無言で捨てる。
final class StateDecoder {
    private let rules: [Rule]
    private(set) var state = DeviceState()
    /// 初回検出時にもポップアップを出すか（起動直後の状態把握用）
    var announceInitial: Bool = true
    /// 対応表に無い生値を受信したときの通知（設定漏れの検出用）。
    /// 引数は (フィールド名, 生値, レポート全文)。同じ値では一度しか呼ばない。
    var onUnmapped: ((String, Int, [UInt8]) -> Void)?
    /// ルールに一致したレポートすべての通知（--debug 用）
    var onMatched: ((Rule, [UInt8], DeviceState) -> Void)?
    private var sawAnything = false
    private var warned = Set<String>()

    init(rules: [Rule]) { self.rules = rules }

    func ingest(_ ev: ReportEvent) -> StateChange? {
        for rule in rules {
            guard rule.applies(usagePage: ev.usagePage, usage: ev.usage,
                               reportId: ev.reportId, bytes: ev.bytes) else { continue }

            let newLayer = rule.layer?.extract(ev.bytes)
            let newAngle = coded(rule.angle, ev.bytes)
            let newDPI = coded(rule.dpi, ev.bytes)
            let newBattery = coded(rule.battery, ev.bytes)

            warnIfUnmapped("向き", newAngle, ev.bytes)
            warnIfUnmapped("DPI", newDPI, ev.bytes)

            if newLayer == nil && newAngle == nil && newDPI == nil && newBattery == nil { continue }
            if let b = newBattery { state.battery = b }

            // バッテリーだけの更新ならポップアップは出さず、値を控えるだけにする
            // （~30 秒おきに自発的に届くため、毎回表示すると邪魔になる）。
            guard newLayer != nil || newAngle != nil || newDPI != nil else {
                onMatched?(rule, ev.bytes, state)
                return nil
            }

            let change = apply(layer: newLayer, angle: newAngle, dpi: newDPI,
                               always: rule.notifiesAlways)
            onMatched?(rule, ev.bytes, state)
            return change
        }
        return nil
    }

    private func warnIfUnmapped(_ field: String, _ v: CodedValue?, _ bytes: [UInt8]) {
        guard let v, !v.isKnown, warned.insert("\(field)/\(v.code)").inserted else { return }
        onUnmapped?(field, v.code, bytes)
    }

    private func coded(_ spec: FieldSpec?, _ bytes: [UInt8]) -> CodedValue? {
        guard let spec, let raw = spec.rawValue(bytes) else { return nil }
        return CodedValue(code: raw, value: spec.converted(raw))
    }

    /// センチネルキー経路など、レポート以外から状態が判明したときの入口。
    /// 生値と表示値が同じ（キーに直接意味を割り当てている）ので code == value とする。
    func apply(layer: Int?, angleDegrees: Int?, dpi: Int?) -> StateChange? {
        apply(layer: layer,
              angle: angleDegrees.map { CodedValue(code: $0, value: $0) },
              dpi: dpi.map { CodedValue(code: $0, value: $0) },
              always: true)
    }

    private func apply(layer: Int?, angle: CodedValue?, dpi: CodedValue?,
                       always: Bool) -> StateChange? {
        let old = state
        if let l = layer { state.layer = l }
        if let a = angle { state.angle = a }
        if let d = dpi { state.dpi = d }

        let first = !sawAnything && announceInitial
        sawAnything = true

        // 判定順が重要（上のコメント参照）。付随して動くフィールドに主役を奪わせない。
        if state.layer != old.layer, let l = state.layer { return .layerPrimary(l) }
        if state.angle != old.angle, let a = state.angle { return .anglePrimary(a) }
        if state.dpi != old.dpi, let d = state.dpi { return .dpiPrimary(d) }

        // 初回は現在値の告知として出す
        if first {
            if let l = state.layer { return .layerPrimary(l) }
            if let a = state.angle { return .anglePrimary(a) }
            if let d = state.dpi { return .dpiPrimary(d) }
        }
        // 値は同じだがボタンは押された
        return always ? .repeatLast : nil
    }

    func reset() {
        state = DeviceState()
        sawAnything = false
        warned.removeAll()
    }
}
