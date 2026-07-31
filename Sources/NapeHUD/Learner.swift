import Foundation

/// 誘導付き学習モード。
///
/// Nape Pro は raw HID (FF60) に状態通知だけでなく定期的なチャタリング（バッテリ／
/// センサ状態など）も流してくる。そのままでは「どのバイトがレイヤーか」を切り分けられない。
///
/// そこで観測を 3 フェーズに分ける:
///   1. 静止           … 操作しない。定期チャタリングの素性を取る（ベースライン）
///   2. レイヤーのみ    … レイヤー切替ボタンだけを押す
///   3. 8 方向切替のみ  … 8 方向切替ボタンだけを押す
///
/// フェーズ 2/3 で「ベースラインに無かった値」が現れたオフセットだけが候補になる。
/// これで定期チャタリングを機械的に除外できる。
///
/// 注: 本体に回転センサーは無く、向きの切替は 8 方向切替ボタンの操作で行われる。
final class Learner {
    /// QMK/ZMK 系の raw HID は 1 本の 32 バイトレポートに複数のコマンドを多重化するため、
    /// 先頭バイト（コマンド ID）までをキーに含めないと別種のレポートが混ざって解析できない。
    struct Key: Hashable, Comparable {
        let page: Int, usage: Int, rid: Int, len: Int, cmd: UInt8
        var tag: String { String(format: "%04X/%02X rid=%d len=%d cmd=%02X", page, usage, rid, len, cmd) }
        static func < (a: Key, b: Key) -> Bool {
            (a.page, a.usage, a.rid, a.len, a.cmd) < (b.page, b.usage, b.rid, b.len, b.cmd)
        }
    }

    enum Phase: Int, CaseIterable {
        case idle = 0, layer = 1, angle = 2
        var title: String {
            switch self {
            case .idle:  return "静止（何も操作しない）"
            case .layer: return "レイヤー切替ボタンのみ"
            case .angle: return "8 方向切替ボタンのみ（8 方向すべて巡回させる）"
            }
        }
    }

    private var values: [Phase: [Key: [Int: Set<UInt8>]]] = [:]
    private var counts: [Phase: [Key: Int]] = [:]
    /// フェーズ内で観測したレポート全文（先頭バイト単位で代表例を残す）
    private var samples: [Phase: [Key: [[UInt8]]]] = [:]
    private var phase: Phase = .idle
    private let ignorePages: Set<Int>
    private let start = Date()

    init(includePointer: Bool) {
        ignorePages = includePointer ? [] : [0x01, 0x0C]
        for p in Phase.allCases { values[p] = [:]; counts[p] = [:]; samples[p] = [:] }
    }

    func begin(_ p: Phase, seconds: Double) {
        phase = p
        let t = String(format: "%6.1f", Date().timeIntervalSince(start))
        print("")
        print("━━━ [\(t)s] フェーズ \(p.rawValue + 1)/3: \(p.title) — \(Int(seconds)) 秒 ━━━")
    }

    func ingest(_ ev: ReportEvent) {
        guard !ignorePages.contains(ev.usagePage) else { return }
        let key = Key(page: ev.usagePage, usage: ev.usage, rid: ev.reportId,
                      len: ev.bytes.count, cmd: ev.bytes.first ?? 0)

        counts[phase]![key, default: 0] += 1
        var perOffset = values[phase]![key] ?? [:]
        for (i, b) in ev.bytes.enumerated() { perOffset[i, default: []].insert(b) }
        values[phase]![key] = perOffset

        var list = samples[phase]![key] ?? []
        // 同一パターンは 1 度だけ残す（先頭 8 バイトで同一判定）
        let head = Array(ev.bytes.prefix(8))
        if !list.contains(where: { Array($0.prefix(8)) == head }), list.count < 24 {
            list.append(ev.bytes)
            samples[phase]![key] = list
            let hex = ev.bytes.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
            print(String(format: "  [%6.1fs] %@  %@ …", Date().timeIntervalSince(start), key.tag, hex))
        } else {
            samples[phase]![key] = list
        }
    }

    // MARK: - 結果

    func report() {
        print("")
        print("══════════ 学習結果 ══════════")

        let allKeys = Set(Phase.allCases.flatMap { values[$0]!.keys }).sorted()
        if allKeys.isEmpty {
            print("レポートを 1 件も受信しませんでした。")
            return
        }

        // 各レポート種別 × オフセットについて、フェーズごとの「新出値」を出す
        struct Cand { let key: Key; let offset: Int; let newInLayer: [UInt8]; let newInAngle: [UInt8] }
        var cands: [Cand] = []

        for key in allKeys {
            let base = values[.idle]![key] ?? [:]
            let lay = values[.layer]![key] ?? [:]
            let ang = values[.angle]![key] ?? [:]
            let width = key.len
            for off in 0..<width {
                let b = base[off] ?? []
                let newL = (lay[off] ?? []).subtracting(b).sorted()
                let newA = (ang[off] ?? []).subtracting(b).sorted()
                if !newL.isEmpty || !newA.isEmpty {
                    cands.append(Cand(key: key, offset: off, newInLayer: newL, newInAngle: newA))
                }
            }
        }

        print("")
        print("── 受信数 ──")
        for key in allKeys {
            let c = Phase.allCases.map { counts[$0]![key] ?? 0 }
            print("  \(key.tag)  静止=\(c[0]) レイヤー=\(c[1]) 8方向=\(c[2])")
        }

        print("")
        print("── ベースラインに無かった値が現れたオフセット ──")
        if cands.isEmpty {
            print("  なし。フェーズ 2/3 で実際にボタンを押しましたか?")
            print("  操作していたのに差が出ない場合、ファームは状態を通知していません。")
            print("  → README の keyFallback（センチネルキー方式）を使ってください。")
        }
        for c in cands.sorted(by: { ($0.key, $0.offset) < ($1.key, $1.offset) }) {
            let l = c.newInLayer.map { String(format: "%02X", $0) }.joined(separator: ",")
            let a = c.newInAngle.map { String(format: "%02X", $0) }.joined(separator: ",")
            // 実測では offset 1（レイヤー）と offset 2（向き）は独立して動くので、
            // 通常はどちらかのフェーズだけで新出値が出る。両方で出た場合は
            // 値の種類が多い側を、そのフェーズ固有の意味を持つ候補とみなす。
            var verdict = "両方で変化"
            if !c.newInLayer.isEmpty && c.newInAngle.isEmpty { verdict = "◀ レイヤー候補" }
            if c.newInLayer.isEmpty && !c.newInAngle.isEmpty { verdict = "◀ 向き候補" }
            if !c.newInLayer.isEmpty && !c.newInAngle.isEmpty {
                if c.newInAngle.count > c.newInLayer.count { verdict = "両方で変化（向き寄り）" }
                if c.newInLayer.count > c.newInAngle.count { verdict = "両方で変化（レイヤー寄り）" }
            }
            print(String(format: "  %@ [%2d]  レイヤー新出={%@} 8方向新出={%@}   %@",
                         c.key.tag, c.offset, l.isEmpty ? "-" : l, a.isEmpty ? "-" : a, verdict))
        }

        // 代表サンプル（人間が目で確かめるため）
        print("")
        print("── 代表レポート（フェーズ別） ──")
        for p in Phase.allCases {
            print("  ● \(p.title)")
            let byKey = samples[p]!
            if byKey.isEmpty { print("    (なし)") }
            for key in byKey.keys.sorted() {
                for s in (byKey[key] ?? []).prefix(8) {
                    let hex = s.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
                    print("    \(key.tag)  \(hex) …")
                }
            }
        }

        emitRules(cands.map { ($0.key, $0.offset, $0.newInLayer, $0.newInAngle) })
    }

    private func emitRules(_ cands: [(Key, Int, [UInt8], [UInt8])]) {
        // レイヤー専用 / 角度専用のオフセットのうち、値の種類が少ないものを最有力とする
        let layerOnly = cands.filter { !$0.2.isEmpty && $0.3.isEmpty }.sorted { $0.2.count < $1.2.count }
        let angleOnly = cands.filter { $0.2.isEmpty && !$0.3.isEmpty }.sorted { $0.3.count < $1.3.count }

        guard let l = layerOnly.first ?? angleOnly.first else { return }
        let key = l.0

        print("")
        print("── config.json 用ルール雛形 ──")
        var lines: [String] = []
        lines.append("  \"rules\": [")
        lines.append("    {")
        lines.append("      \"name\": \"learned\",")
        lines.append("      \"usagePage\": \(key.page),")
        lines.append("      \"usage\": \(key.usage),")
        lines.append("      \"reportId\": \(key.rid),")
        lines.append("      \"minLength\": \(key.len),")

        // 先頭バイト（コマンド ID）を match に入れて、他種レポートの誤採用を防ぐ。
        lines.append("      \"match\": [ { \"offset\": 0, \"equals\": [\(key.cmd)] } ],")

        var body: [String] = []
        if let lo = layerOnly.first, lo.0 == key {
            body.append("      \"layer\": { \"offset\": \(lo.1) }")
        }
        if let ao = angleOnly.first, ao.0 == key {
            let vals = ao.3
            let map = vals.enumerated().map { "\"\($0.element)\": \($0.offset * 45)" }.joined(separator: ", ")
            body.append("      \"angle\": { \"offset\": \(ao.1), \"map\": { \(map) } }")
        }
        lines.append(body.joined(separator: ",\n"))
        lines.append("    }")
        lines.append("  ]")
        print(lines.joined(separator: "\n"))
        print("")
        print("※ angle の map は「観測された順に 45° 刻み」を仮置きしたもの。")
        print("　 8 方向すべてを巡回させたうえで `nape-hud calibrate` を使うと、")
        print("　 押した順に対応づけた表が作れます。")
    }
}
