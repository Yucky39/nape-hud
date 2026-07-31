import Foundation

/// 読み出したキーマップを整形する。CLI とアプリの窓で同じ文字列を使うので、
/// CLI で見た内容がそのまま画面に出る（片方だけ壊れることがない）。
enum KeymapReport {

    static func text(_ s: VIAClient.Snapshot, layerName: (Int) -> String) -> String {
        var out: [String] = []
        out.append("Keychron Nape Pro キーアサイン（VIA プロトコルで読み出し）")
        out.append("プロトコル版数 \(s.protocolVersion) / レイヤー \(s.layerCount)"
                   + (s.reportedLayerCount != s.layerCount
                      ? "（デバイス申告 \(s.reportedLayerCount) / Launcher が見せるのは \(s.layerCount)）" : "")
                   + " / マトリクス \(s.matrixRows) 行 × \(s.keysPerLayer) 列"
                   + " / ダイヤル \(s.encoderCount) 個"
                   + " / マクロ \(s.macroCount) スロット\(s.macrosEmpty ? "（未使用）" : "")")
        out.append(s.coordinateVerified
                   ? "キー数は座標指定の読み出し（0x04）と一致を確認済み"
                   : "⚠️ キー数の自動判定を座標読みで検算できませんでした。keymap.keysPerLayer で固定してください")
        out.append("")
        out.append("⚠️ これは VIA のキーマップ領域の生の内容です。Launcher の表示とは一致しません。")
        out.append("　 実機の割り当ては「レイヤー(0〜7) × 角度(0°〜315°) × 単押し/長押し」で決まり、")
        out.append("　 その全体はこの領域には入っていません（角度別の読み出しは未実装）。")
        out.append("　 正確な内容は Keychron Launcher で確認してください。")
        out.append("")

        // 見出し。列番号はマトリクスの列（row 0 の col 0…）に対応する
        let keyCols = (0..<max(s.keysPerLayer, 1)).map { "col\($0)" }
        let header = pad("レイヤー", 16) + keyCols.map { pad($0, 12) }.joined()
            + pad("ダイヤル↻", 12) + pad("ダイヤル↺", 12)
        out.append(header)
        out.append(String(repeating: "─", count: 16 + (s.keysPerLayer + 2) * 12))

        var vendorCodes = Set<UInt16>()
        for l in 0..<s.layerCount {
            let row = l < s.keymap.count ? s.keymap[l] : []
            var line = pad("\(l): \(layerName(l))", 16)
            for k in 0..<s.keysPerLayer {
                let code = k < row.count ? row[k] : 0
                if code >= 0x7E00 { vendorCodes.insert(code) }
                line += pad(Keycode.shortName(code), 12)
            }
            let enc = l < s.encoders.count ? s.encoders[l] : (cw: 0, ccw: 0)
            line += pad(Keycode.shortName(enc.cw), 12) + pad(Keycode.shortName(enc.ccw), 12)
            out.append(line)
        }

        out.append("")
        out.append("凡例")
        out.append("  ----      未割り当て")
        out.append("  TRNS      下位レイヤーを透過")
        out.append("  Btn1〜5   マウスボタン / WhUp・WhDn = ホイール / Vol± = 音量")
        out.append("  ⌘C 等     修飾キー付きの組み合わせ")
        out.append("  LYR:xxxx  レイヤー関連のキーコード。正確な意味は未確認")
        out.append("            （QMK の並びに当てると番号がレイヤー数と合わないため名前を出さない）")
        if !vendorCodes.isEmpty {
            out.append("  KC:7Exx   Keychron 独自キーコード（名称非公開）。観測値: "
                       + vendorCodes.sorted().map { String(format: "0x%04X", $0) }.joined(separator: ", "))
        }

        // 全レイヤーで同じ値が入っている列。レイヤーに依らない割り当ての手掛かりになる。
        if s.keysPerLayer > 0, s.keymap.count == s.layerCount, s.layerCount > 1 {
            var common: [String] = []
            for c in 0..<s.keysPerLayer {
                let column = s.keymap.compactMap { c < $0.count ? $0[c] : nil }
                if column.count == s.layerCount, Set(column).count == 1, let v = column.first, v != 0 {
                    common.append("col\(c) = \(Keycode.shortName(v))")
                }
            }
            if !common.isEmpty {
                out.append("")
                out.append("全レイヤーで同じ値が入っている列")
                out.append("  " + common.joined(separator: " / "))
            }
        }

        out.append("")
        out.append("── 実機の仕様 ──")
        out.append("  レイヤー   全 8 段（状態通知は 1〜8、Launcher の表示は 0〜7）")
        out.append("  OctaShift  0° / 45° / 90° / 135° / 180° / 225° / 270° / 315° の 8 方向")
        out.append("  割り当て可 6 キー（M1 / M2 / 01 / 02 / 03 / 04）＋ ダイヤル上下")
        out.append("  各キーは「単押し」と「長押し」で別の動作を割り当てられる")
        out.append("             （Launcher の `右クリック | C(KC_UP)` のような表記が 単押し | 長押し）")
        out.append("  割り当ては レイヤー × 角度 × 単押し/長押し の組み合わせごとに保持される")
        out.append("")
        out.append("※ 上の表の列番号は VIA のマトリクス座標（0x04 で確認）です。")
        out.append("　 6 個の物理キー（M1〜04）や単押し/長押しとの対応は取れていません。")
        return out.joined(separator: "\n")
    }

    /// 全角文字を 2 桁として数え、等幅で桁を揃える
    private static func pad(_ s: String, _ width: Int) -> String {
        let w = s.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
        return s + String(repeating: " ", count: max(1, width - w))
    }

    private static func isWide(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        // CJK・かな・全角記号・矢印など、等幅フォントで 2 桁になるもの
        return (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v)
            || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0xFE30...0xFE6F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v)
            || v == 0x21BB || v == 0x21BA   // ↻ ↺
    }
}
