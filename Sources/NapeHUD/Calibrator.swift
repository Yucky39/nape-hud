import Foundation

/// 向きコード → 実際の角度の対応表を実測で作るモード。
///
/// Nape Pro の向きフィールドは 0〜7 のインデックスではなく独自の値（実測で 0x06 / 0x90）を返す。
/// 本体に回転センサーは無く、向きは 8 方向切替ボタンで順に切り替わるので、
/// 「基準の向きから 8 方向切替ボタンを押していき、初出順に等間隔の角度を割り当てる」方式で表を作る。
/// ボタンは決まった順に巡回するため、押した順＝向きの並び順になる。
final class Calibrator {
    private let rules: [Rule]
    private let settings: CalibrationConfig
    /// 設定・既存の map から決まる 0° の基準コード（無ければ nil）
    private let preferredZeroCode: Int?
    /// 初出順に並んだ向きコード
    private(set) var codes: [Int] = []
    /// 各コードで観測されたレイヤー値（OctaShift は向きに応じてレイヤーも切替える）
    private var layersByCode: [Int: Set<Int>] = [:]
    /// 押した順の並び。先頭コードが再登場したら 1 周したと判定できる。
    private var sequence: [Int] = []
    private(set) var completedCycle = false

    /// 1 周あたりの方向数。これだけ集まれば 1 周ぶん揃ったと判断して完了にする。
    /// （先頭コードの再登場を待つ設計だと、8 個揃ってもあと 1 回押さないと完了しない）
    var expectedPositions: Int { max(settings.positions, 2) }

    /// 0° の位置をずらす量（方向数を法とする）。UI から前後に動かせる。
    var rotation = 0
    /// UI から 0° の基準を直接選んだ場合の値。設定より優先する。
    var chosenZeroCode: Int?
    /// 1 周を検出したときの通知。これを終了条件にすれば Ctrl-C 待ちが不要になる。
    var onCycleComplete: (() -> Void)?
    /// 新しい向きを検出したときの通知（何番目か, 生コード, そのときのレイヤー）。GUI 用。
    var onDetected: ((Int, Int, Int?) -> Void)?
    /// true にすると標準出力へ書かない（GUI から使うとき）
    var quiet = false
    private let start = Date()

    init(rules: [Rule], settings: CalibrationConfig = .init()) {
        self.rules = rules
        self.settings = settings
        // 0° の基準は「設定」→「既存の map で 0° のコード」の順で引き継ぐ。
        // どちらも無ければ開始時の向き（最後に検出された向き）を 0° とする。
        if let explicit = settings.angleZeroCode {
            preferredZeroCode = explicit
        } else if let map = rules.compactMap({ $0.angle?.map }).first,
                  let zero = map.first(where: { $0.value == 0 })?.key,
                  let code = Int(zero) {
            preferredZeroCode = code
        } else {
            preferredZeroCode = nil
        }
    }

    /// 0° の基準がどこから来たかの説明（UI 表示用）
    var zeroSourceNote: String {
        if chosenZeroCode != nil || rotation != 0 { return "手動で選択" }
        if settings.angleZeroCode != nil { return "設定 calibration.angleZeroCode" }
        if preferredZeroCode != nil { return "既存の angle.map を引き継ぎ" }
        return "開始時の向き"
    }

    /// angle フィールドを持つ最初のルール。これが無いと校正できない。
    var hasAngleRule: Bool { rules.contains { $0.angle != nil } }

    func ingest(_ ev: ReportEvent) {
        for rule in rules {
            guard let spec = rule.angle,
                  rule.applies(usagePage: ev.usagePage, usage: ev.usage,
                               reportId: ev.reportId, bytes: ev.bytes),
                  let raw = spec.rawValue(ev.bytes) else { continue }

            let layer = rule.layer?.rawValue(ev.bytes)
            if let l = layer { layersByCode[raw, default: []].insert(l) }

            // 同じコードが連続するのは同一状態の再通知なので並びには足さない
            if sequence.last != raw { sequence.append(raw) }

            if !codes.contains(raw) {
                codes.append(raw)
                if !quiet {
                    let t = String(format: "%6.1f", Date().timeIntervalSince(start))
                    let layerNote = layer.map { " (レイヤー \($0))" } ?? ""
                    print("  [\(t)s] 向き #\(codes.count) を検出: コード 0x\(String(format: "%02X", raw)) = \(raw)\(layerNote)")
                }
                onDetected?(codes.count, raw, layer)
                if codes.count >= expectedPositions, !completedCycle {
                    completedCycle = true
                    if !quiet {
                        print("  \(codes.count) 方向ぶん揃いました（1 周）。")
                    }
                    onCycleComplete?()
                }
            } else if !completedCycle, codes.count > 1, raw == codes[0] {
                completedCycle = true
                if !quiet {
                    let t = String(format: "%6.1f", Date().timeIntervalSince(start))
                    print("  [\(t)s] 最初の向きに戻りました → \(codes.count) 方向で 1 周です。")
                }
                onCycleComplete?()
            }
            return
        }
    }

    /// 1 方向ぶんの角度（8 方向なら 45°）
    var step: Int { codes.count > 1 ? 360 / codes.count : 0 }

    /// 0° を割り当てる検出番号（0 始まり）。
    ///
    /// 基準が指定されていなければ **最後の検出**。
    /// 状態通知は「ボタンを押した *後* の向き」を返すため、最初に検出される向きは
    /// 開始時の向きの次であり、1 周ぶん押し終えたときの最後の検出が開始時の向きになる。
    /// つまり「0° にしたい向きから始める」運用ではこれが正解になる。
    /// 基準コードが分かっている場合はそれを使うので、**どの向きから始めてもよい**。
    var zeroIndex: Int {
        let n = codes.count
        guard n > 0 else { return 0 }
        let base: Int
        if let code = chosenZeroCode ?? preferredZeroCode, let i = codes.firstIndex(of: code) {
            base = i
        } else {
            base = n - 1
        }
        return ((base + rotation) % n + n) % n
    }

    /// i 番目（0 始まり）に検出した向きに割り当てる角度。
    func degrees(forIndex i: Int) -> Int {
        let n = codes.count
        guard n > 0 else { return 0 }
        let delta = settings.clockwise ? (i - zeroIndex) : (zeroIndex - i)
        return ((delta % n) + n) % n * step
    }

    /// 生コード → 度数の対応表
    func suggestedMap() -> [Int: Int] {
        var m: [Int: Int] = [:]
        for (i, c) in codes.enumerated() { m[c] = degrees(forIndex: i) }
        return m
    }

    /// いま 0° に割り当てられている生コード
    var zeroCode: Int? {
        codes.enumerated().first { degrees(forIndex: $0.offset) == 0 }?.element
    }

    /// config.json に貼れる JSON 断片
    func mapJSON() -> String {
        let m = suggestedMap()
        let body = m.keys.sorted().map { "\"\($0)\": \(m[$0]!)" }.joined(separator: ", ")
        return "{ \(body) }"
    }

    func report() {
        print("")
        print("══════════ 校正結果 ══════════")
        if codes.isEmpty {
            print("向きの値を 1 件も検出できませんでした。")
            if !hasAngleRule {
                print("config.json の rules に angle フィールドを持つルールがありません。")
                print("先に `nape-hud learn` でルールを確定させてください。")
            } else {
                print("8 方向切替ボタンを実際に押しましたか? Keychron Launcher は閉じていますか?")
            }
            return
        }

        print("検出した向き: \(codes.count) 種\(completedCycle ? "（1 周を確認）" : "")")
        for (i, c) in codes.enumerated() {
            let layers = (layersByCode[c] ?? []).sorted().map(String.init).joined(separator: ",")
            print(String(format: "  #%d  コード 0x%02X (%3d) → %3d°  対応レイヤー: %@",
                         i + 1, c, c, degrees(forIndex: i), layers.isEmpty ? "-" : layers))
        }
        if let z = zeroCode {
            print(String(format: "  0° = コード 0x%02X（%@）", z, zeroSourceNote as NSString))
        }

        print("")
        print("── config.json の angle に貼る map ──")
        print("      \"angle\": { \"offset\": <learn で確定した offset>, \"map\": \(mapJSON()) }")
        print("")
        print("※ どの向きから校正を始めてもよくするには、0° にしたい向きの生コードを")
        print("　 config.json の calibration.angleZeroCode に書いてください。")
        print("　 未設定なら「開始時の向き」を 0° とみなします（1 周すると最後に戻るため）。")
        print("　 回転方向が逆に感じる場合は calibration.clockwise を false にしてください。")
        if codes.count < expectedPositions {
            print("")
            print("※ OctaShift は 8 方向。まだ \(codes.count) 種しか出ていません。")
            print("　 8 方向切替ボタンを押し続けて 1 周させると全部そろいます。")
            print("　 （途中で止めると刻み幅が \(step)° になり実際とずれます）")
        }
    }
}
