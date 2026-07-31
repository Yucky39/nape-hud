import Foundation

/// QMK / VIA のキーコードを人が読める名前にする。
///
/// 実機で観測できた範囲は確定情報として扱い、推測に頼る範囲（レイヤー操作・
/// メーカー独自）は末尾に `?` を付けて区別する。生の 16 進は常に併記できるようにする。
enum Keycode {

    /// 短い表示名（グリッド用・ASCII 中心で桁が揃う）
    static func shortName(_ code: UInt16) -> String {
        switch code {
        case 0x0000: return "----"          // KC_NO
        case 0x0001: return "TRNS"          // 透過
        default: break
        }

        // 修飾つき（QK_MODS: 0x0100〜0x1FFF）
        if code >= 0x0100 && code <= 0x1FFF {
            let mods = (code >> 8) & 0x1F
            let base = UInt16(code & 0xFF)
            let right = mods & 0x10 != 0
            var parts: [String] = []
            if mods & 0x01 != 0 { parts.append(right ? "R^" : "^") }      // Ctrl
            if mods & 0x02 != 0 { parts.append(right ? "R⇧" : "⇧") }      // Shift
            if mods & 0x04 != 0 { parts.append(right ? "R⌥" : "⌥") }      // Option
            if mods & 0x08 != 0 { parts.append(right ? "R⌘" : "⌘") }      // Command
            return parts.joined() + basic(base)
        }

        // レイヤー関連と思われる領域。
        // QMK の並びに当てると 0x522A/0x522B は MO(10)/MO(11) になるが、
        // このデバイスのレイヤー数は 9 なので番号が合わない。
        // 誤った名前を出すより生の値を見せる。
        if code >= 0x5000 && code <= 0x5FFF {
            return String(format: "LYR:%04X", code)
        }

        // メーカー独自（QK_KB / QK_USER 領域）
        if code >= 0x7E00 && code <= 0x7FFF {
            return String(format: "KC:%04X", code)
        }

        if code <= 0x00FF { return basic(UInt16(code)) }
        return String(format: "%04X", code)
    }

    /// 詳しい説明（凡例・一覧用）
    static func description(_ code: UInt16) -> String {
        switch code {
        case 0x0000: return "未割り当て"
        case 0x0001: return "下位レイヤーを透過"
        default: break
        }
        if code >= 0x7E00 && code <= 0x7FFF {
            return "Keychron 独自キーコード（OctaShift / DPI 切替などが該当。名称は非公開）"
        }
        if let n = names[code] { return n }
        if code >= 0x0100 && code <= 0x1FFF {
            return "修飾キー付き: \(shortName(code))"
        }
        if code >= 0x5000 && code <= 0x5FFF {
            return "レイヤー関連のキーコード（正確な意味は未確認）"
        }
        return "不明"
    }

    /// 基本キーコード（HID Usage）
    private static func basic(_ code: UInt16) -> String {
        if let n = shortNames[code] { return n }
        // 英字 / 数字
        if code >= 0x04 && code <= 0x1D {
            let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            return String(letters[Int(code - 0x04)])
        }
        if code >= 0x1E && code <= 0x26 { return String(code - 0x1D) }   // 1..9
        if code == 0x27 { return "0" }
        if code >= 0x3A && code <= 0x45 { return "F\(code - 0x39)" }     // F1..F12
        if code >= 0x68 && code <= 0x73 { return "F\(code - 0x5F)" }     // F13..F24
        return String(format: "%02X", code)
    }

    private static let shortNames: [UInt16: String] = [
        0x28: "Enter", 0x29: "Esc", 0x2A: "BSpc", 0x2B: "Tab", 0x2C: "Space",
        0x2D: "-", 0x2E: "=", 0x2F: "[", 0x30: "]", 0x31: "\\",
        0x33: ";", 0x34: "'", 0x35: "`", 0x36: ",", 0x37: ".", 0x38: "/",
        0x39: "Caps", 0x46: "PrtSc", 0x47: "ScrLk", 0x48: "Pause",
        0x49: "Ins", 0x4A: "Home", 0x4B: "PgUp", 0x4C: "Del", 0x4D: "End", 0x4E: "PgDn",
        0x4F: "→", 0x50: "←", 0x51: "↓", 0x52: "↑",
        0xA8: "Mute", 0xA9: "Vol+", 0xAA: "Vol-",
        0xAB: "Next", 0xAC: "Prev", 0xAD: "Stop", 0xAE: "Play",
        0xCD: "MsUp", 0xCE: "MsDn", 0xCF: "MsLt", 0xD0: "MsRt",
        0xD1: "Btn1", 0xD2: "Btn2", 0xD3: "Btn3", 0xD4: "Btn4", 0xD5: "Btn5",
        0xD9: "WhUp", 0xDA: "WhDn", 0xDB: "WhLt", 0xDC: "WhRt",
        0xE0: "LCtl", 0xE1: "LSft", 0xE2: "LAlt", 0xE3: "LCmd",
        0xE4: "RCtl", 0xE5: "RSft", 0xE6: "RAlt", 0xE7: "RCmd",
    ]

    private static let names: [UInt16: String] = [
        0x00A8: "ミュート", 0x00A9: "音量アップ", 0x00AA: "音量ダウン",
        0x00AB: "次のトラック", 0x00AC: "前のトラック",
        0x00AD: "停止", 0x00AE: "再生 / 一時停止",
        0x00CD: "マウス移動 上", 0x00CE: "マウス移動 下",
        0x00CF: "マウス移動 左", 0x00D0: "マウス移動 右",
        0x00D1: "マウス左ボタン", 0x00D2: "マウス右ボタン", 0x00D3: "マウス中ボタン",
        0x00D4: "マウスボタン 4（戻る）", 0x00D5: "マウスボタン 5（進む）",
        0x00D9: "ホイール 上", 0x00DA: "ホイール 下",
        0x00DB: "ホイール 左", 0x00DC: "ホイール 右",
        0x0028: "Enter", 0x0029: "Esc", 0x002A: "Backspace", 0x002B: "Tab", 0x002C: "Space",
        0x004A: "Home", 0x004B: "Page Up", 0x004D: "End", 0x004E: "Page Down",
        0x004F: "→", 0x0050: "←", 0x0051: "↓", 0x0052: "↑",
    ]
}
