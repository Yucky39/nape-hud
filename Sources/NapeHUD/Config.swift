import Foundation

// MARK: - Config model
//
// すべての「どのバイトがレイヤー/角度なのか」という知識は設定ファイル側に置く。
// ファームウェア更新でレポート形式が変わっても、再ビルドせずに追随できる。

struct Config: Codable {
    var device: DeviceMatch = .init()
    var hud: HUDConfig = .init()
    var layerNames: [String: String] = [:]
    var angleNames: [String: String] = [:]
    /// DPI 段の表示名。キーは map 適用後の値（map 未指定なら生値）。
    /// 例 {"0": "800", "1": "1200"} → HUD に「1200 DPI」と出る
    var dpiNames: [String: String] = [:]
    /// 生 HID レポートから状態を取り出す規則。上から順に評価し、最初に一致したものを使う。
    var rules: [Rule] = []
    /// レポートを一切吐かないファームウェア向けの保険。センチネルキーで状態を受け取る。
    var keyFallback: KeyFallback = .init()
    /// デバイスが自発通知しない場合、こちらから定期的に問い合わせる。
    var poll: Poll = .init()
    /// 向きの校正（calibrate / アプリ内校正）の挙動
    var calibration: CalibrationConfig = .init()
    /// キーアサイン表示（VIA プロトコル読み出し）の設定
    var keymap: KeymapConfig = .init()

    enum CodingKeys: String, CodingKey {
        case device, hud, layerNames, angleNames, dpiNames, rules, keyFallback, poll,
             calibration, keymap
    }

    static let defaultPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/nape-hud/config.json")

    static func load(_ path: URL?) throws -> Config {
        let url = path ?? Config.defaultPath
        guard let data = try? Data(contentsOf: url) else {
            if path != nil {
                throw Err("設定ファイルが読めません: \(url.path)")
            }
            return Config()   // 未設定なら組み込みデフォルト
        }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .useDefaultKeys
        do {
            return try dec.decode(Config.self, from: data)
        } catch {
            throw Err("設定ファイルの解析に失敗: \(url.path)\n  \(error)")
        }
    }
}

struct DeviceMatch: Codable {
    var vendorId: Int = 0x3434                     // Keychron
    var productIds: [Int] = [0x0440]               // Nape Pro (USB / 2.4GHz ドングル / BT で異なる場合は追記)
    /// productIds が空、または PID が未知でも製品名で拾う（BT 接続時の PID 差異対策）。
    var productNameContains: [String] = ["Nape"]
    /// 接続種別の表示名を PID 単位で上書きする。キーは "0x0441" のような 16 進、または 10 進文字列。
    /// 例: 2.4GHz ドングルが別 PID で見える場合 {"0x0441": "2.4GHz"}
    var connectionNames: [String: String] = [:]
    /// 監視する HID インターフェース（PrimaryUsagePage）。
    ///
    /// 既定はベンダ面のみ: 0xFF60（raw HID / 状態通知）と 0x008C（Keychron ベンダチャネル）。
    /// キーボード面（0x0001）を含めると macOS の「入力監視」許可が必要になり、
    /// 未許可だと IOHIDManagerOpen 自体が kIOReturnNotPermitted で失敗する。
    /// 状態通知はベンダ面に来るので、通常運用では許可なしで動く。
    /// 空配列にすると全インターフェースを対象にする（= 許可が必要）。
    var usagePages: [Int] = [0xFF60, 0x008C]

    enum CodingKeys: String, CodingKey {
        case vendorId, productIds, productNameContains, connectionNames, usagePages
    }

    func matches(vid: Int, pid: Int, product: String) -> Bool {
        guard vid == vendorId else { return false }
        if productIds.contains(pid) { return true }
        return productNameContains.contains { !$0.isEmpty && product.localizedCaseInsensitiveContains($0) }
    }

    func connectionOverride(pid: Int) -> String? {
        connectionNames[String(format: "0x%04X", pid)]
            ?? connectionNames[String(format: "0x%04x", pid)]
            ?? connectionNames[String(pid)]
    }
}

struct HUDConfig: Codable {
    var seconds: Double = 2.2
    var position: String = "topRight"   // center | top | topLeft | topRight | bottomLeft | bottomRight | bottom
    var margin: Double = 28
    var scale: Double = 1.0
    var showConnection: Bool = true
    var showOnConnectionChange: Bool = true
    var showAngleDial: Bool = true
    var followsMouseScreen: Bool = true
    /// メニューバー常駐項目を出すか。false にすると終了手段が SIGTERM だけになるので注意。
    var showMenuBarIcon: Bool = true
    /// メニューバーに現在のレイヤー番号を添えるか
    var menuBarShowsLayer: Bool = true
    /// レイヤー番号の表示補正。
    ///
    /// デバイスの状態通知は 1〜8 を返すが、Keychron Launcher は同じものを 0〜7 と表示する。
    /// -1 にすると Launcher の番号に揃う。layerNames のキーも補正後の番号で引く。
    var layerNumberOffset: Int = 0

    enum CodingKeys: String, CodingKey {
        case seconds, position, margin, scale, showConnection, showOnConnectionChange,
             showAngleDial, followsMouseScreen, showMenuBarIcon, menuBarShowsLayer,
             layerNumberOffset
    }
}

// MARK: - Rules

struct Rule: Codable {
    var name: String = ""
    var usagePage: Int?
    var usage: Int?
    var reportId: Int?
    var minLength: Int?
    /// 固定バイト照合（コマンド ID の判別など）
    var match: [ByteMatch]?
    var layer: FieldSpec?
    var angle: FieldSpec?
    /// DPI（CPI）段。実測では Nape Pro は offset 3 に 0x00〜0x04 の 5 段を返す。
    var dpi: FieldSpec?
    /// always   … 一致したレポートが来たら毎回ポップアップ（既定）
    /// onChange … 値が前回と変わったときだけポップアップ
    ///
    /// Nape Pro の状態通知は静止中には一切飛ばず、ボタンを押したときだけ届く。
    /// 8 方向切替ボタンを押したのに「同じ角度だから」と抑制されては困るので既定は always。
    var notify: String = "always"

    enum CodingKeys: String, CodingKey {
        case name, usagePage, usage, reportId, minLength, match, layer, angle, dpi, notify
    }

    var notifiesAlways: Bool { notify.lowercased() != "onchange" }

    func applies(usagePage up: Int, usage us: Int, reportId rid: Int, bytes: [UInt8]) -> Bool {
        if let v = usagePage, v != up { return false }
        if let v = usage, v != us { return false }
        if let v = reportId, v != rid { return false }
        if let v = minLength, bytes.count < v { return false }
        for m in match ?? [] where !m.matches(bytes) { return false }
        return true
    }
}

struct ByteMatch: Codable {
    var offset: Int
    /// いずれかに一致すれば OK
    var equals: [Int]?
    var mask: Int?

    func matches(_ b: [UInt8]) -> Bool {
        guard offset >= 0, offset < b.count else { return false }
        var v = Int(b[offset])
        if let m = mask { v &= m }
        guard let eq = equals, !eq.isEmpty else { return true }
        return eq.contains(v)
    }
}

/// 生バイト列から 1 つの数値（レイヤー番号 / 角度）を取り出す指定。
struct FieldSpec: Codable {
    var offset: Int
    var size: Int = 1
    /// value          … そのまま数値として読む（リトルエンディアン）
    /// bitmaskHighest … 立っている最上位ビットの位置（ZMK/QMK の layer_state ビットマップ用）
    /// bitmaskLowest  … 立っている最下位ビットの位置
    var encoding: String = "value"
    var bigEndian: Bool = false
    /// 読んだ生値に対する補正: (raw + add) * multiply
    var add: Int = 0
    var multiply: Double = 1
    /// 生値 → 表示値の明示マッピング（例 {"0":0,"1":90,"2":180,"3":270}）。指定時は add/multiply より優先。
    var map: [String: Int]?

    private enum CodingKeys: String, CodingKey {
        case offset, size, encoding, bigEndian, add, multiply, map
    }

    init(from decoder: Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        offset = try c.decode(Int.self, forKey: .offset)
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 1
        encoding = try c.decodeIfPresent(String.self, forKey: .encoding) ?? "value"
        bigEndian = try c.decodeIfPresent(Bool.self, forKey: .bigEndian) ?? false
        add = try c.decodeIfPresent(Int.self, forKey: .add) ?? 0
        multiply = try c.decodeIfPresent(Double.self, forKey: .multiply) ?? 1
        map = try c.decodeIfPresent([String: Int].self, forKey: .map)
    }

    init(offset: Int, size: Int = 1, encoding: String = "value", map: [String: Int]? = nil) {
        self.offset = offset; self.size = size; self.encoding = encoding; self.map = map
    }

    /// map を適用した最終値。map 指定時にマップ外だった場合は nil（= 未校正）。
    func extract(_ b: [UInt8]) -> Int? {
        guard let raw = rawValue(b) else { return nil }
        return converted(raw)
    }

    /// 生値 → 表示値。map があればその引き当て、無ければ add/multiply 補正。
    func converted(_ raw: Int) -> Int? {
        if let m = map { return m[String(raw)] }
        return Int((Double(raw + add) * multiply).rounded())
    }

    /// map / add / multiply を適用する前の生値。calibrate や未マップ警告で使う。
    func rawValue(_ b: [UInt8]) -> Int? {
        guard offset >= 0, size > 0, offset + size <= b.count else { return nil }
        let slice = Array(b[offset..<(offset + size)])

        var raw = 0
        switch encoding {
        case "bitmaskHighest", "bitmaskLowest":
            var bits: [Int] = []
            for (i, byte) in slice.enumerated() {
                for bit in 0..<8 where byte & (1 << bit) != 0 {
                    bits.append(i * 8 + bit)
                }
            }
            guard let picked = (encoding == "bitmaskHighest" ? bits.max() : bits.min()) else { return nil }
            raw = picked
        default:
            let ordered = bigEndian ? slice : slice.reversed().map { $0 }
            for byte in ordered { raw = (raw << 8) | Int(byte) }
        }
        return raw
    }

    /// map が指定されているか（未マップ値の警告判定に使う）
    var hasMap: Bool { map != nil }
}

// MARK: - Fallbacks

struct KeyFallback: Codable {
    var enabled: Bool = false
    /// センチネルキーをアプリ側で食い止め、実際の文字入力を発生させない。
    var consume: Bool = true
    var bindings: [KeyBinding] = []

    enum CodingKeys: String, CodingKey { case enabled, consume, bindings }
}

struct KeyBinding: Codable {
    var keyCode: Int
    /// 修飾キー要求（"cmd","opt","ctrl","shift" の配列）。省略時は修飾なしを要求。
    var modifiers: [String]?
    var layer: Int?
    var angle: Int?
    var dpi: Int?
}

/// 向きの校正の設定。
///
/// 既定では「校正を始めた向きを 0° とみなす」。これは 8 方向切替ボタンを 1 周押すと
/// 最後に開始時の向きへ戻ることを利用している。
/// `angleZeroCode` を書いておけば **どの向きから校正を始めてもよくなる**。
struct CalibrationConfig: Codable {
    /// 1 周あたりの方向数。OctaShift は 8。ここまで検出したら校正完了とみなす。
    var positions: Int = 8
    /// この生コードの向きを 0° とする（例: 0 なら 0x00 を 0°）。
    /// null のときは「現在の angle.map で 0° になっているコード」→
    /// それも無ければ「開始時の向き（最後に検出された向き）」を 0° とする。
    var angleZeroCode: Int?
    /// ボタンを押す方向に対して角度を増やすか。
    /// 実際の回転と逆に感じる場合は false にすると 45° ずつ減る向きで割り当てる。
    var clockwise: Bool = true

    enum CodingKeys: String, CodingKey { case positions, angleZeroCode, clockwise }
}

/// キーアサイン表示の設定。
struct KeymapConfig: Codable {
    /// 1 レイヤーあたりのキー数。0 なら自動判定（非ゼロのキーコードの個数から割り出す）。
    /// 末尾のキーが未割り当てだと自動判定が少なく出るので、その場合はここで固定する。
    var keysPerLayer: Int = 0
    /// 表示するレイヤー数。0 ならデバイスの申告値（VIA の 0x11）をそのまま使う。
    ///
    /// Nape Pro では 0x11 が 9 を返すが、Keychron Launcher が見せるのは 0〜7 の 8 レイヤー。
    /// 9 番目は Launcher に出てこない内部レイヤーなので、既定では 8 に絞る。
    var layerCount: Int = 8

    enum CodingKeys: String, CodingKey { case keysPerLayer, layerCount }
}

struct Poll: Codable {
    var enabled: Bool = false
    var usagePage: Int = 0xFF60
    var usage: Int = 0x61
    var reportId: Int = 0
    /// 送信するバイト列
    var request: [Int] = []
    var intervalMs: Int = 500

    enum CodingKeys: String, CodingKey {
        case enabled, usagePage, usage, reportId, request, intervalMs
    }
}

// MARK: -

struct Err: LocalizedError {
    let msg: String
    init(_ m: String) { msg = m }
    var errorDescription: String? { msg }
}
