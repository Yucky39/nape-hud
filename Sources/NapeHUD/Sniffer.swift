import Foundation

/// レポート形式の解析用モード。
/// レイヤー切替ボタン / 8 方向切替ボタンを押しながら流れるバイト列を観測し、
/// 「どのオフセットが動いたか」を最後にまとめて出す。ここで得た結果をそのまま
/// config.json の rules に書き写せる。
final class Sniffer {
    /// 先頭バイト（コマンド ID）までキーに含める。1 本のレポートに複数種が多重化されるため。
    private struct Key: Hashable { let page: Int; let usage: Int; let rid: Int; let len: Int; let cmd: UInt8 }
    private struct Track {
        var count = 0
        var first: [UInt8] = []
        var last: [UInt8] = []
        /// オフセットごとに観測された値の集合
        var values: [Set<UInt8>] = []
    }

    private var tracks: [Key: Track] = [:]
    private let start = Date()
    private let showEvery: Bool
    private let ignorePages: Set<Int>

    /// - Parameters:
    ///   - verbose: 1 レポートごとに 1 行出す（トラックボール移動で流れるので既定は間引き）
    ///   - includePointer: マウス/キーボード面も含める
    init(verbose: Bool, includePointer: Bool) {
        self.showEvery = verbose
        self.ignorePages = includePointer ? [] : [0x01, 0x0C]
    }

    func ingest(_ ev: ReportEvent) {
        guard !ignorePages.contains(ev.usagePage) else { return }
        let key = Key(page: ev.usagePage, usage: ev.usage, rid: ev.reportId,
                      len: ev.bytes.count, cmd: ev.bytes.first ?? 0)
        var t = tracks[key] ?? {
            var t = Track()
            t.first = ev.bytes
            t.values = Array(repeating: Set<UInt8>(), count: ev.bytes.count)
            return t
        }()

        var changed: [Int] = []
        for (i, b) in ev.bytes.enumerated() {
            if i < t.values.count {
                t.values[i].insert(b)
            } else {
                t.values.append([b])
            }
            if i < t.last.count, t.last[i] != b { changed.append(i) }
        }
        let isNew = t.count == 0
        t.count += 1
        t.last = ev.bytes
        tracks[key] = t

        if showEvery || isNew || !changed.isEmpty {
            let ts = String(format: "%8.3f", Date().timeIntervalSince(start))
            let marks = Set(changed)
            let hex = ev.bytes.enumerated().map { i, b in
                marks.contains(i) ? "[\(String(format: "%02X", b))]" : String(format: " %02X ", b)
            }.joined()
            let tag = String(format: "%04X/%02X", ev.usagePage, ev.usage)
            print("[\(ts)] \(tag) rid=\(ev.reportId) len=\(ev.bytes.count) \(ev.connection.symbol)  \(hex)")
            fflush(stdout)
        }
    }

    func printSummary() {
        print("")
        print("──────── 解析結果 ────────")
        if tracks.isEmpty {
            print("レポートを 1 件も受信しませんでした。")
            print("・レイヤー切替ボタン / 8 方向切替ボタンを実際に押しましたか?")
            print("・キーボード面(0001/06)を見るには --pointer と「入力監視」の許可が必要です。")
            print("・ベンダ面(FF60 / 008C)が無音なら、ファーム側が状態を通知しない可能性があります。")
            print("  その場合は keyFallback（センチネルキー方式）を使ってください。")
            return
        }
        for (key, t) in tracks.sorted(by: { ($0.key.page, $0.key.rid) < ($1.key.page, $1.key.rid) }) {
            let tag = String(format: "%04X/%02X", key.page, key.usage)
            print("")
            print("● \(tag) reportId=\(key.rid) len=\(key.len) cmd=\(String(format: "%02X", key.cmd))  受信 \(t.count) 件")
            print("  固定バイト:")
            var fixed: [String] = []
            var varying: [(Int, [UInt8])] = []
            for (i, set) in t.values.enumerated() {
                if set.count == 1, let v = set.first {
                    fixed.append(String(format: "  [%2d]=%02X", i, v))
                } else {
                    varying.append((i, set.sorted()))
                }
            }
            print(fixed.isEmpty ? "    (なし)" : fixed.joined())
            print("  変化したバイト:")
            if varying.isEmpty {
                print("    (なし)")
            } else {
                for (i, vals) in varying {
                    let shown = vals.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                    let more = vals.count > 16 ? " …(\(vals.count) 種)" : " (\(vals.count) 種)"
                    print(String(format: "    [%2d] %@%@", i, shown, more))
                }
                print("")
                print("  → config.json のルール雛形:")
                print(suggestRule(key: key, track: t, varying: varying))
            }
        }
        print("")
        print("値が 2〜8 種類だけ動いたオフセットがレイヤー/角度の候補です。")
        print("レイヤー切替だけ／8 方向切替だけで別々に sniff すると特定が確実です（`learn` が自動化します）。")
    }

    /// 変化オフセットのうち値の種類が少ないものを候補としてルール雛形を作る。
    private func suggestRule(key: Key, track t: Track, varying: [(Int, [UInt8])]) -> String {
        let candidates = varying.filter { $0.1.count <= 10 }.sorted { $0.1.count < $1.1.count }
        let layerOff = candidates.first?.0
        let angleOff = candidates.dropFirst().first?.0

        let fixedMatch = ["{ \"offset\": 0, \"equals\": [\(key.cmd)] }"]

        var lines: [String] = []
        lines.append("    {")
        lines.append("      \"name\": \"\(String(format: "%04X", key.page))-cmd\(String(format: "%02X", key.cmd))\",")
        lines.append("      \"usagePage\": \(key.page),")
        lines.append("      \"usage\": \(key.usage),")
        lines.append("      \"reportId\": \(key.rid),")
        lines.append("      \"minLength\": \(key.len),")
        if !fixedMatch.isEmpty {
            lines.append("      \"match\": [ \(fixedMatch.joined(separator: ", ")) ],")
        }
        if let l = layerOff {
            lines.append("      \"layer\": { \"offset\": \(l) }\(angleOff != nil ? "," : "")")
        }
        if let a = angleOff {
            let vals = t.values[a].sorted()
            let map = vals.enumerated()
                .map { "\"\($0.element)\": \($0.offset * 45)" }
                .joined(separator: ", ")
            lines.append("      \"angle\": { \"offset\": \(a), \"map\": { \(map) } }")
        }
        lines.append("    }")
        return lines.joined(separator: "\n")
    }
}
