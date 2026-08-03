import AppKit
import Foundation

// パイプ／リダイレクト時も観測ログが即座に読めるように行バッファへ。
setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - 引数

var mode = "run"
var configPath: URL?
var verbose = false
var includePointer = false
var debug = false
var sniffSeconds: Double = 0
var secondsGiven = false

/// 観測系モードの既定の打ち切り時間。
/// 無制限（Ctrl-C 待ち）だと、タイムアウトのある実行環境から呼ばれたときに
/// 結果を出さずに殺されてしまうので、明示指定が無ければ必ず自動終了させる。
let defaultObserveSeconds: Double = 90

var args = Array(CommandLine.arguments.dropFirst())
if let first = args.first, !first.hasPrefix("-") {
    mode = first
    args.removeFirst()
}
var it = args.makeIterator()
while let a = it.next() {
    switch a {
    case "--config", "-c":
        if let p = it.next() { configPath = URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
    case "--verbose", "-v": verbose = true
    case "--pointer", "-p": includePointer = true
    case "--debug", "-d": debug = true
    case "--seconds", "-s":
        if let n = it.next(), let d = Double(n) { sniffSeconds = d; secondsGiven = true }
    case "--help", "-h": mode = "help"
    default:
        FileHandle.standardError.write("不明なオプション: \(a)\n".data(using: .utf8)!)
        exit(2)
    }
}

func usage() {
    print("""
    nape-hud — Keychron Nape Pro のレイヤー / OctaShift 角度 / DPI をポップアップ表示

    使い方:
      nape-hud [run]              常駐してレイヤー・角度・DPI の切替をポップアップ表示
      nape-hud devices            接続中のインターフェースと接続種別を一覧
      nape-hud sniff              生 HID レポートを観測し、末尾に解析結果を出す
      nape-hud learn              誘導付き学習（静止→レイヤー→8方向切替）でルールを特定
      nape-hud calibrate          8方向切替ボタンを1周させて「向きコード → 角度」の対応表を作る
      nape-hud keymap             デバイスに登録されたキーアサインを読み出して表示
      nape-hud test               HUD の見た目を確認（ダミー表示）
      nape-hud selftest           合成レポートで復号経路を検証（実機不要・原因切り分け用）
      nape-hud doctor             権限と設定の健診

    オプション:
      -c, --config <path>   設定ファイル（既定 ~/.config/nape-hud/config.json）
      -v, --verbose         sniff で全レポートを表示（既定は変化があった行のみ）
      -p, --pointer         sniff でキーボード/マウス面も含める（要「入力監視」許可）
      -s, --seconds <n>     sniff / calibrate / learn の観測秒数（既定 90 秒、0 で無制限）
      -d, --debug           run で一致レポート全文と復号結果を標準出力に流す

    sniff / calibrate は指定秒数で自動終了して結果を出す（Ctrl-C でも即出力）。
    calibrate は 8 方向を 1 周した時点で自動終了する。
    """)
}

// MARK: - 共通ロード

let config: Config
do {
    config = try Config.load(configPath)
} catch {
    FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}

/// デバイスの生のレイヤー値（1〜8）を表示用の番号に直す。
/// Launcher は同じレイヤーを 0〜7 と呼ぶので、hud.layerNumberOffset = -1 で揃えられる。
func displayLayer(_ raw: Int) -> Int { raw + config.hud.layerNumberOffset }

/// 表示用のレイヤー名。layerNames のキーは補正後の番号で引く。
func layerName(_ raw: Int) -> String { layerNameByNumber(displayLayer(raw)) }

/// 設定画面での編集を再起動なしで効かせるための差し替え先。
/// 名前は表示にしか使わないので、その場で反映して構わない。
var layerNameOverride: [String: String]?

/// すでに表示用の番号になっているものの名前。
/// キーアサイン表示は VIA のレイヤー番号（Launcher と同じ 0 起点）を使うので、
/// 二重に補正しないようこちらを使う。
func layerNameByNumber(_ n: Int) -> String {
    (layerNameOverride ?? config.layerNames)[String(n)] ?? "Layer \(n)"
}
func angleName(_ deg: Int) -> String {
    config.angleNames[String(deg)] ?? "\(deg)°"
}

/// 意味の切り分けに使えるよう、先頭 8 バイトだけを読みやすく並べる。
func hexDump(_ b: [UInt8], limit: Int = 8) -> String {
    let head = b.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
    return b.count > limit ? "\(head) …(\(b.count)B)" : head
}

/// 校正済みなら角度名、未校正なら生コードを見せる。
/// 未校正を無表示にすると「ボタンを押したのに何も出ない」になって原因が分からなくなる。
func angleTitle(_ a: CodedValue) -> String {
    if let d = a.value { return angleName(d) }
    return String(format: "コード 0x%02X（未校正）", a.code)
}

/// DPI の表示名。
/// rules の dpi.map で「段 → 実 DPI 値」に変換済みなので、ここでは値をそのまま数値表示する。
/// dpiNames に文字列を書けばラベルを差し替えられる。
/// map に無い段は数値が分からないので、生コードを見せて設定漏れに気づけるようにする。
func dpiTitle(_ d: CodedValue) -> String {
    guard let v = d.value else {
        return String(format: "段 0x%02X（DPI 値 未設定）", d.code)
    }
    if let name = config.dpiNames[String(v)] {
        return Int(name) != nil ? "\(name) DPI" : name   // 数値だけなら単位を添える
    }
    return "\(v) DPI"
}

// MARK: - モード分岐

switch mode {

case "help":
    usage()

case "devices":
    // 接続方式（BT / 2.4GHz / 有線）でデバイスの見え方が変わるため、
    // 一致したものだけでなく **すべての HID デバイス** を出し、
    // 一致しない場合はその理由まで示す。原因がここで判断できるようにする。
    print("nape-hud devices — HID デバイスの一覧と照合結果")
    print("")
    print("設定の照合条件:")
    print("  vendorId            : 0x\(String(format: "%04X", config.device.vendorId))")
    print("  productIds          : \(config.device.productIds.map { String(format: "0x%04X", $0) }.joined(separator: ", "))")
    print("  productNameContains : \(config.device.productNameContains.joined(separator: ", "))")
    let pagesCfg = config.device.usagePages
    print("  usagePages（監視面）: \(pagesCfg.isEmpty ? "全面" : pagesCfg.map { String(format: "0x%04X", $0) }.joined(separator: ", "))")
    print("")

    let all = HIDMonitor.enumerateAll()
    guard !all.isEmpty else { print("HID デバイスを列挙できませんでした。"); exit(1) }

    // 同一デバイスの複数インターフェースをまとめて見せる
    let grouped = Dictionary(grouping: all) { "\($0.vendorId)-\($0.productId)-\($0.product)" }
    var matchedAny = false
    // 判定はデバイス単位で行う。別デバイス（同じ Keychron のドングルやキーボード）に
    // 0xFF60 があるのを見て「検出できる」と誤判定してはいけない。
    var capable: [String] = []      // 状態通知を受け取れるデバイス
    var incapable: [(String, String)] = []   // 受け取れないデバイス（名前, 接続）

    for key in grouped.keys.sorted() {
        let ifaces = grouped[key]!.sorted { $0.usagePage < $1.usagePage }
        guard let first = ifaces.first else { continue }
        let matches = config.device.matches(vid: first.vendorId, pid: first.productId,
                                            product: first.product)
        // Keychron 以外で一致もしないものは出しても混乱するだけなので、
        // VID が一致するものか、名前に候補語を含むものだけ詳しく出す
        let interesting = first.vendorId == config.device.vendorId
            || config.device.productNameContains.contains {
                   !$0.isEmpty && first.product.localizedCaseInsensitiveContains($0) }
        guard interesting || matches else { continue }

        print("\(matches ? "✅ 一致" : "❌ 不一致")  \(first.product.isEmpty ? "(名称なし)" : first.product)")
        print("   VID/PID   : \(String(format: "0x%04X / 0x%04X", first.vendorId, first.productId))")
        print("   接続       : \(first.transport)")
        print("   インターフェース:")
        for i in ifaces {
            let watched = pagesCfg.isEmpty || pagesCfg.contains(i.usagePage)
            let note = i.usagePage == 0xFF60 ? "  ← 状態通知が来る面" : ""
            print(String(format: "     0x%04X/0x%02X  %@%@",
                         i.usagePage, i.usage,
                         (watched ? "監視対象" : "監視対象外") as NSString, note as NSString))
        }
        if matches {
            matchedAny = true
            let hasVendor = ifaces.contains {
                $0.usagePage == 0xFF60 && (pagesCfg.isEmpty || pagesCfg.contains($0.usagePage))
            }
            if hasVendor { capable.append("\(first.product) [\(first.transport)]") }
            else { incapable.append((first.product, first.transport)) }
        } else {
            // 一致しない理由を明示する
            var why: [String] = []
            if first.vendorId != config.device.vendorId { why.append("vendorId が違う") }
            if !config.device.productIds.contains(first.productId) {
                why.append("productIds に 0x\(String(format: "%04X", first.productId)) が無い")
            }
            if !config.device.productNameContains.contains(where: {
                !$0.isEmpty && first.product.localizedCaseInsensitiveContains($0) }) {
                why.append("productNameContains に一致する語が無い")
            }
            print("   不一致の理由: \(why.joined(separator: " / "))")
            print("   → 対処: config.json の device.productIds に 0x\(String(format: "%04X", first.productId)) を追加")
        }
        print("")
    }

    print("── 判定 ──")
    if !matchedAny {
        print("❌ 照合条件に一致するデバイスがありません。")
        print("   上記の「不一致の理由」と対処を確認してください。")
    } else {
        if !capable.isEmpty {
            print("✅ 状態通知を受け取れる経路:")
            capable.forEach { print("     \($0)") }
        }
        if !incapable.isEmpty {
            print("❌ 状態通知を受け取れない経路（0xFF60 の面が無い）:")
            incapable.forEach { print("     \($0.0) [\($0.1)]") }
            print("   この経路で操作している間は HUD が出ません。")
            print("   → 対処: 有線 / 2.4GHz ドングルを使う、または keyFallback（センチネルキー方式）")
        }
        if capable.isEmpty {
            print("")
            print("   いま使っている経路では検出できません。")
        }
    }

case "doctor":
    print("nape-hud 健診")
    print("─────────────")
    print("設定ファイル      : \((configPath ?? Config.defaultPath).path) \(FileManager.default.fileExists(atPath: (configPath ?? Config.defaultPath).path) ? "✅" : "⚠️ 未作成（既定値で動作）")")
    print("ルール数          : \(config.rules.count) \(config.rules.isEmpty ? "⚠️ 未設定 → learn で特定してください" : "✅")")
    let fields = config.rules.reduce(into: [String]()) { acc, r in
        if r.layer != nil, !acc.contains("レイヤー") { acc.append("レイヤー") }
        if r.angle != nil, !acc.contains("向き") { acc.append("向き") }
        if r.dpi != nil, !acc.contains("DPI") { acc.append("DPI") }
    }
    print("検出対象          : \(fields.isEmpty ? "⚠️ なし" : fields.joined(separator: " / "))")
    // DPI は段番号しか届かないので、実 DPI 値への変換表が入っているかを明示する
    if let dpi = config.rules.compactMap({ $0.dpi }).first {
        print("DPI 段の対応表    : \(dpi.hasMap ? "✅ 設定あり（実値は Launcher で要確認）" : "⚠️ map 未設定 → 段番号が DPI 値として表示されます")")
    }
    let pages = config.device.usagePages
    print("監視面            : \(pages.isEmpty ? "全インターフェース（⚠️ 入力監視の許可が必要）" : pages.map { String(format: "0x%04X", $0) }.joined(separator: " / "))")
    print("入力監視 (HID)    : \(inputMonitoringGranted() ? "✅ 許可" : "未許可（ベンダ面のみなら不要。-p / 全面監視のとき必要）")")
    print("アクセシビリティ  : \(KeyWatcher.accessibilityGranted ? "✅ 許可" : "⚠️ 未許可（keyFallback に必要）")")
    print("keyFallback       : \(config.keyFallback.enabled ? "有効 (\(config.keyFallback.bindings.count) 件)" : "無効")")
    print("ポーリング        : \(config.poll.enabled ? "有効 (\(config.poll.intervalMs)ms)" : "無効")")
    let mon = HIDMonitor(match: config.device, allUsagePages: true)
    try? mon.start()
    CFRunLoopRunInMode(.defaultMode, 0.6, false)
    print("デバイス          : \(mon.interfaceSummary.isEmpty ? "⚠️ 未検出" : "✅ \(mon.interfaceSummary.count) インターフェース / \(mon.activeConnection.rawValue)")")

case "sniff":
    if includePointer && !inputMonitoringGranted() {
        print("「入力監視」が未許可です。許可ダイアログを出します…")
        _ = requestInputMonitoring()
        print("システム設定 → プライバシーとセキュリティ → 入力監視 で許可後、もう一度実行してください。")
    }
    let sniffer = Sniffer(verbose: verbose, includePointer: includePointer)
    let mon = HIDMonitor(match: config.device, allUsagePages: includePointer)
    mon.onLog = { print("· \($0)") }
    mon.onReport = { sniffer.ingest($0) }
    do { try mon.start() } catch {
        FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!); exit(1)
    }

    let sniffLimit = secondsGiven ? sniffSeconds : defaultObserveSeconds
    print("観測を開始しました。レイヤー切替ボタンと 8 方向切替ボタンを押してください。")
    print(sniffLimit > 0
          ? "（\(Int(sniffLimit)) 秒で自動終了して解析結果を出します。Ctrl-C でも即出力）"
          : "（終了して解析結果を出すには Ctrl-C）")
    print("")

    signal(SIGINT, SIG_IGN)
    let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sig.setEventHandler { sniffer.printSummary(); exit(0) }
    sig.resume()

    if config.poll.enabled {
        Timer.scheduledTimer(withTimeInterval: Double(config.poll.intervalMs) / 1000, repeats: true) { _ in
            mon.send(usagePage: config.poll.usagePage, usage: config.poll.usage,
                     reportId: config.poll.reportId, bytes: config.poll.request.map { UInt8($0 & 0xFF) })
        }
    }
    if sniffLimit > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + sniffLimit) {
            sniffer.printSummary(); exit(0)
        }
    }
    CFRunLoopRun()

case "learn":
    let each = sniffSeconds > 0 ? sniffSeconds : 25
    let learner = Learner(includePointer: includePointer)
    let mon = HIDMonitor(match: config.device, allUsagePages: includePointer)
    mon.onLog = { print("· \($0)") }
    mon.onReport = { learner.ingest($0) }
    do { try mon.start() } catch {
        FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!); exit(1)
    }

    print("誘導付き学習を開始します（各フェーズ \(Int(each)) 秒 / 全体 \(Int(each * 3)) 秒）。")
    print("画面の指示どおりに、指定された操作だけを行ってください。")

    let phases = Learner.Phase.allCases
    for (i, p) in phases.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + each * Double(i)) {
            learner.begin(p, seconds: each)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + each * Double(phases.count)) {
        learner.report(); exit(0)
    }
    signal(SIGINT, SIG_IGN)
    let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sig.setEventHandler { learner.report(); exit(0) }
    sig.resume()
    CFRunLoopRun()

case "keymap":
    // VIA プロトコルでデバイスからキーマップを読み出して表示する。
    // 非同期完了まで実行ループを回す（結果が来るか失敗するまで待つ）。
    var done = false
    var exitCode: Int32 = 0
    VIAClient.readSnapshot(match: config.device,
                           settings: config.keymap) { result in
        switch result {
        case .success(let snap):
            print(KeymapReport.text(snap, layerName: layerNameByNumber))
        case .failure(let error):
            FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
            exitCode = 1
        }
        done = true
    }
    let deadline = Date().addingTimeInterval(20)
    while !done, Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.05, false) }
    if !done {
        FileHandle.standardError.write("読み出しがタイムアウトしました。\n".data(using: .utf8)!)
        exitCode = 1
    }
    exit(exitCode)

case "selftest":
    // 実機なしで復号経路を検証する。合成レポートを現在の config のルールに通し、
    // 「レイヤーだけ変えたとき」「向きだけ変えたとき」に期待どおりの結果が出るか確かめる。
    // 実機で検知できない場合、原因がこちら側かデバイス側かの切り分けに使う。
    guard let rule = config.rules.first(where: { $0.layer != nil || $0.angle != nil || $0.dpi != nil }) else {
        print("rules が空です。config.json を確認してください。"); exit(1)
    }
    let up = rule.usagePage ?? 0xFF60
    let us = rule.usage ?? 0x61
    let rid = rule.reportId ?? 0
    let cmd = UInt8(rule.match?.first(where: { $0.offset == 0 })?.equals?.first ?? 0xA3)

    func synthetic(_ layer: UInt8, _ dir: UInt8, _ dpi: UInt8) -> ReportEvent {
        var b = [UInt8](repeating: 0, count: 32)
        b[0] = cmd; b[1] = layer; b[2] = dir; b[3] = dpi
        return ReportEvent(usagePage: up, usage: us, reportId: rid,
                           bytes: b, connection: .usb, product: "synthetic")
    }

    let dec = StateDecoder(rules: config.rules)
    dec.onUnmapped = { field, raw, _ in
        print("    (\(field): 対応表に無い値 0x\(String(format: "%02X", raw)))")
    }

    // (レイヤー, 向き, DPI, 説明)
    // 「レイヤーのみ・向き付随」はレイヤー切替ボタンで普通に起きる（レイヤーごとに向きが
    // 記憶されているため）。このときレイヤー主役にならないと実機でレイヤーが検知できない。
    let steps: [(UInt8, UInt8, UInt8, String)] = [
        (1, 3, 2, "初回受信"),
        (2, 3, 2, "レイヤーのみ 1→2"),
        (3, 3, 2, "レイヤーのみ 2→3"),
        (3, 4, 2, "向きのみ 3→4"),
        (3, 4, 2, "同じ値で再通知（ボタン再押し）"),
        (3, 4, 3, "DPIのみ 2→3"),
        (3, 4, 0, "DPIのみ 3→0（巡回）"),
        (4, 5, 0, "レイヤーのみ・向き付随"),
    ]
    print("ルール: \(rule.name.isEmpty ? "(無名)" : rule.name)")
    print("cmd=0x\(String(format: "%02X", cmd))"
          + " layer.offset=\(rule.layer?.offset.description ?? "-")"
          + " angle.offset=\(rule.angle?.offset.description ?? "-")"
          + " dpi.offset=\(rule.dpi?.offset.description ?? "-")")
    print("")
    var failures = 0
    for (l, d, p, note) in steps {
        let change = dec.ingest(synthetic(l, d, p))
        let desc: String
        switch change {
        case .some(.layerPrimary(let n)): desc = "レイヤー主役 → Layer \(n) (\(layerName(n)))"
        case .some(.anglePrimary(let a)): desc = "角度主役 → \(angleTitle(a))"
        case .some(.dpiPrimary(let v)):   desc = "DPI 主役 → \(dpiTitle(v))"
        case .some(.repeatLast):          desc = "直前表示の再掲"
        case .none:                       desc = "表示なし"
        }
        let pad = String(repeating: " ", count: max(0, 30 - note.count * 2))
        print(String(format: "  A3 %02X %02X %02X …  ", l, d, p) + note + pad + desc)

        // 期待どおりの主役になっているかを検証する
        func expect(_ prefix: String, _ ok: Bool, _ what: String) {
            guard note.hasPrefix(prefix), !ok else { return }
            failures += 1
            print("    ❌ \(what)として検出されていません")
        }
        if case .some(.layerPrimary) = change {
            expect("レイヤーのみ", true, "")
        } else { expect("レイヤーのみ", false, "レイヤー変化がレイヤー主役") }
        if case .some(.anglePrimary) = change {
            expect("向きのみ", true, "")
        } else { expect("向きのみ", false, "向き変化が角度主役") }
        if case .some(.dpiPrimary) = change {
            expect("DPIのみ", true, "")
        } else { expect("DPIのみ", false, "DPI 変化が DPI 主役") }
    }
    // 校正の角度割り当てを検証する。
    // 状態通知は「押した後の向き」を返すので、開始時の向き（= 0° にしたい向き）は
    // 最後に検出される。実測の押し順で 0x00 が 0° になることを確かめる。
    print("")
    print("── 校正の角度割り当ての検証 ──")
    // 既存 map からの継承を混ぜずに割り当てロジック自体を見るため、map 無しのルールで検証する。
    var bare = Rule()
    bare.usagePage = up
    bare.usage = us
    bare.reportId = rid
    bare.match = [ByteMatch(offset: 0, equals: [Int(cmd)], mask: nil)]
    bare.layer = FieldSpec(offset: 1)
    bare.angle = FieldSpec(offset: 2)

    /// 開始時の向きが 0x00 のとき、押すたびに 0x01,0x02,…,0x07,0x00 と通知される
    func calibrated(_ settings: CalibrationConfig) -> [Int: Int] {
        let cal = Calibrator(rules: [bare], settings: settings)
        cal.quiet = true
        for code in [1, 2, 3, 4, 5, 6, 7, 0] as [UInt8] { cal.ingest(synthetic(1, code, 2)) }
        return cal.suggestedMap()
    }
    func line(_ m: [Int: Int]) -> String {
        (0...7).map { "0x0\($0)=\(m[$0].map(String.init) ?? "-")°" }.joined(separator: " ")
    }
    func check(_ label: String, _ m: [Int: Int], _ expectZero: Int, _ expect45: Int) {
        let ok = m[expectZero] == 0 && m[expect45] == 45
            && Set(m.values) == Set(stride(from: 0, to: 360, by: 45))
        print("  \(label)")
        print("    \(line(m))")
        print(ok ? "    ✅ 0x0\(expectZero) が 0°"
                 : "    ❌ 期待と違います（期待: 0x0\(expectZero)=0°, 0x0\(expect45)=45°）")
        if !ok { failures += 1 }
    }

    print("  押し順 01→02→…→07→00（開始時の向き 0x00）")
    // 既定: 基準未指定 → 開始時の向き（最後の検出 = 0x00）が 0°
    check("既定（angleZeroCode 未設定）", calibrated(CalibrationConfig()), 0, 1)
    // 任意の向きから始められることの確認: 基準を明示すると開始位置に依存しない
    var zero3 = CalibrationConfig(); zero3.angleZeroCode = 3
    check("angleZeroCode = 3", calibrated(zero3), 3, 4)
    var zero5 = CalibrationConfig(); zero5.angleZeroCode = 5
    check("angleZeroCode = 5", calibrated(zero5), 5, 6)
    // 回転方向の反転
    var ccw = CalibrationConfig(); ccw.clockwise = false
    let m = calibrated(ccw)
    let ccwOK = m[0] == 0 && m[7] == 45
    print("  clockwise = false")
    print("    \(line(m))")
    print(ccwOK ? "    ✅ 逆回りに割り当てられています（0x07=45°）"
                : "    ❌ 逆回りになっていません")
    if !ccwOK { failures += 1 }

    // 既存 map からの引き継ぎ（config を書き換えずに前回の基準を維持できるか）
    if let existing = config.rules.first?.angle?.map,
       let inheritedZero = existing.first(where: { $0.value == 0 })?.key {
        let m = calibrated(CalibrationConfig())
        _ = m
        let cal = Calibrator(rules: config.rules, settings: CalibrationConfig())
        cal.quiet = true
        for code in [1, 2, 3, 4, 5, 6, 7, 0] as [UInt8] { cal.ingest(synthetic(1, code, 2)) }
        let ok = cal.suggestedMap()[Int(inheritedZero) ?? -1] == 0
        print("  既存 map の 0°（コード \(inheritedZero)）の引き継ぎ")
        print(ok ? "    ✅ 引き継げています（基準: \(cal.zeroSourceNote)）"
                 : "    ❌ 引き継げていません")
        if !ok { failures += 1 }
    }

    // 画面構成の検証。大きさの違う画面を並べると
    // 「外接矩形の内側だがどの画面にも属さない」領域が生まれ、そこへカーソルを
    // 送ると system が引き戻して跳ねる。加速はその領域を避ける必要がある。
    print("")
    print("── 画面構成の検証 ──")
    do {
        let rects = PointerAccelerator.displayBounds
        var union = CGRect.null
        rects.forEach { union = union.union($0) }
        var invalid = 0, total = 0
        var y = union.minY
        while y < union.maxY {
            var x = union.minX
            while x < union.maxX {
                total += 1
                if !rects.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { invalid += 1 }
                x += 40
            }
            y += 40
        }
        print("  画面 \(rects.count) 枚 / 外接矩形 \(Int(union.width))×\(Int(union.height))")
        let pct = total > 0 ? invalid * 100 / total : 0
        print("  外接矩形内の無効領域: \(pct)%"
              + (pct > 0 ? "（矩形で丸めると跳ねるため、有効判定で回避している）" : ""))
        // 無効領域があっても不具合ではない。回避できていることが重要。
        let probe = CGPoint(x: union.maxX - 1, y: union.maxY - 1)
        let inside = rects.contains { $0.contains(probe) }
        print("  外接矩形の隅が有効か: \(inside ? "有効" : "無効 → 加速はこの点へ送らない")")

        // 画面サイズに応じた倍率調整（有効時の効き方を数値で見せる）
        var ds = config.acceleration.displayScaling
        let wasEnabled = ds.enabled
        ds.enabled = true                 // 無効設定でも「有効ならどうなるか」を出す
        let a = config.acceleration
        print("  画面サイズ調整\(wasEnabled ? "（有効）" : "（現在は無効。有効時の値）")"
              + " 指標=\(ds.metric) 基準=\(ds.referenceSize > 0 ? "\(Int(ds.referenceSize))pt" : "主画面")")
        for d in PointerAccelerator.displayScaleSummary(config: ds) {
            let top = a.baseGain + (a.maxGain - a.baseGain) * d.scale
            print(String(format: "    %@ %@ → 調整 %.2fx / 実効上限 %.2fx",
                         d.name as NSString, d.size as NSString, d.scale, top))
        }
    }

    // ポインタ加速のカーブ検証（設定が無効でも計算そのものは確かめる）
    print("")
    print("── ポインタ加速のカーブ検証 ──")
    do {
        let a = config.acceleration
        func g(_ v: Double) -> Double { PointerAccelerator.gain(forSpeed: v, config: a) }
        let below = g(max(a.thresholdSpeed - 50, 0))
        let above = g(a.fullSpeed + 500)
        let mid = g((a.thresholdSpeed + a.fullSpeed) / 2)
        print(String(format: "  設定: %.1fx → %.1fx / %.0f〜%.0f px/s%@",
                     a.baseGain, a.maxGain, a.thresholdSpeed, a.fullSpeed,
                     (a.enabled ? "" : "（現在は無効）") as NSString))
        print(String(format: "  低速(%.0f)=%.2fx  中速(%.0f)=%.2fx  高速(%.0f)=%.2fx",
                     max(a.thresholdSpeed - 50, 0), below,
                     (a.thresholdSpeed + a.fullSpeed) / 2, mid,
                     a.fullSpeed + 500, above))
        var ok = abs(below - a.baseGain) < 0.001 && abs(above - a.maxGain) < 0.001
        // 単調増加であること（途中で戻ると操作感が破綻する）
        var prev = -1.0
        for i in 0...20 {
            let v = a.thresholdSpeed + (a.fullSpeed - a.thresholdSpeed) * Double(i) / 20
            let cur = g(v)
            if cur < prev - 0.0001 { ok = false; break }
            prev = cur
        }
        print(ok ? "  ✅ しきい値未満は等倍、上限で最大、間は単調増加"
                 : "  ❌ カーブが期待どおりではありません")
        if !ok { failures += 1 }
    }

    // 校正ウインドウのレイアウト検証。
    // 内容の必要サイズがウインドウ内寸を超えていると、ボタン列が見えなくなる。
    print("")
    print("── 校正ウインドウのレイアウト検証 ──")
    if rule.angle != nil {
        _ = NSApplication.shared   // ウインドウ生成に必要
        let win = CalibrationController(rules: config.rules, settings: config.calibration,
                                        configURL: configPath ?? Config.defaultPath)
        func fitCheck(_ label: String) {
            let (needed, actual) = win.layoutFit
            let ok = needed.height <= actual.height + 0.5 && needed.width <= actual.width + 0.5
            print(String(format: "  %@ 必要 %.0f×%.0f / 実際 %.0f×%.0f  %@",
                         label as NSString, needed.width, needed.height,
                         actual.width, actual.height,
                         (ok ? "✅" : "❌ はみ出しています") as NSString))
            if !ok { failures += 1 }
        }
        fitCheck("初期状態:")
        // 8 方向ぶん検出させて一覧が折り返した状態でも収まるか
        for code in [1, 2, 3, 4, 5, 6, 7, 0] as [UInt8] {
            win.injectForTesting(synthetic(1, code, 2))
        }
        fitCheck("8 方向検出後:")
    } else {
        print("  angle ルールが無いのでスキップしました")
    }

    print("")
    print("── 設定ウインドウのレイアウト検証 ──")
    do {
        _ = NSApplication.shared
        let sw = SettingsController(config: config, configURL: configPath ?? Config.defaultPath)
        for pane in sw.paneFits {
            let ok = pane.needed.height <= pane.available.height + 0.5
                && pane.needed.width <= pane.available.width + 0.5
            print(String(format: "  %@タブ: 必要 %.0f×%.0f / 収まる範囲 %.0f×%.0f  %@",
                         pane.label as NSString, pane.needed.width, pane.needed.height,
                         pane.available.width, pane.available.height,
                         (ok ? "✅" : "❌ はみ出しています") as NSString))
            if !ok { failures += 1 }
        }
    }

    // 設定ファイルへの書き戻し（アプリ内校正で使う経路）を一時コピーで検証する。
    // コメント付き JSON を壊さずに map だけ差し替えられているかを確かめる。
    print("")
    print("── 設定ファイル書き戻しの検証（一時コピーに対して実行） ──")
    let srcURL = configPath ?? Config.defaultPath
    if FileManager.default.fileExists(atPath: srcURL.path) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nape-hud-selftest-\(ProcessInfo.processInfo.processIdentifier).json")
        try? FileManager.default.removeItem(at: tmp)
        do {
            try FileManager.default.copyItem(at: srcURL, to: tmp)
            let sample = "{ \"1\": 0, \"2\": 90, \"3\": 180, \"0\": 270 }"
            // 設定画面からの保存経路（複数の値をまとめて置換）
            let edits: [(path: [String], json: String)] = [
                (["hud", "seconds"], "3.5"),
                (["hud", "position"], "\"center\""),
                (["hud", "showAngleDial"], "false"),
                (["hud", "layerNumberOffset"], "-1"),
                (["acceleration", "enabled"], "true"),
                (["acceleration", "maxGain"], "4.5"),
                (["layerNames"], "{ \"1\": \"テスト\" }"),
            ]
            if case .written = try ConfigWriter.setValues(edits, in: tmp) {
                let r = try Config.load(tmp)
                let ok = r.hud.seconds == 3.5 && r.hud.position == "center"
                    && r.hud.showAngleDial == false && r.hud.layerNumberOffset == -1
                    && r.acceleration.enabled == true && r.acceleration.maxGain == 4.5
                    && r.layerNames["1"] == "テスト"
                    // 触っていない項目が保たれているか
                    && r.rules.count == config.rules.count
                    && r.device.usagePages == config.device.usagePages
                print(ok ? "  ✅ 設定画面からの保存（7 項目）が正しく反映され、他の項目も無傷"
                         : "  ❌ 設定画面からの保存結果が期待と違います")
                if !ok { failures += 1 }
                let text = try String(contentsOf: tmp, encoding: .utf8)
                let comments = text.components(separatedBy: "\"//").count - 1
                print("  コメントキー: \(comments) 個 残存（保存後）")
            } else {
                print("  ❌ 設定画面からの保存で対象が見つかりませんでした")
                failures += 1
            }

            switch try ConfigWriter.updateAngleMap(sample, in: tmp) {
            case .written:
                let after = try Data(contentsOf: tmp)
                _ = try JSONSerialization.jsonObject(with: after)   // 壊れていないか
                let reloaded = try Config.load(tmp)
                let got = reloaded.rules.first?.angle?.map ?? [:]
                let ok = got == ["1": 0, "2": 90, "3": 180, "0": 270]
                print(ok ? "  ✅ map の差し替えに成功し、再読み込みできました"
                         : "  ❌ 差し替え後の map が期待と違います: \(got)")
                if !ok { failures += 1 }
                // コメント（"//" キー）が残っているか
                let text = String(data: after, encoding: .utf8) ?? ""
                let comments = text.components(separatedBy: "\"//").count - 1
                print("  コメントキー: \(comments) 個 残存")
            case .targetNotFound:
                print("  ⚠️ rules[].angle を特定できませんでした（アプリ内校正では手貼りになります）")
            }
        } catch {
            print("  ❌ 検証に失敗: \(error.localizedDescription)")
            failures += 1
        }
        try? FileManager.default.removeItem(at: tmp)
    } else {
        print("  設定ファイルが無いのでスキップしました")
    }

    print("")
    if failures == 0 {
        print("✅ 復号経路は正常。レイヤー / 向き / DPI の各バイトが変われば必ず対応する表示になります。")
        print("   実機で検知できない項目があれば、そのボタンはそのバイトを動かしていません。")
        print("   `nape-hud learn -s 20` で、実際に動くバイトを特定してください。")
    } else {
        print("❌ \(failures) 件の不整合。config.json のルールを見直してください。")
        exit(1)
    }

case "calibrate":
    let cal = Calibrator(rules: config.rules, settings: config.calibration)
    let mon = HIDMonitor(match: config.device)
    mon.onReport = { cal.ingest($0) }
    do { try mon.start() } catch {
        FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!); exit(1)
    }
    guard cal.hasAngleRule else {
        FileHandle.standardError.write("""
            config.json の rules に angle フィールドを持つルールがありません。
            先に `nape-hud learn` でルールを確定させてください。

            """.data(using: .utf8)!)
        exit(1)
    }
    let calLimit = secondsGiven ? sniffSeconds : defaultObserveSeconds
    print("向きの校正を開始します。Keychron Launcher は閉じてください。")
    print("基準の向き（0° とみなす向き）から始めて、8 方向切替ボタンを 1 周ぶん押してください。")
    print("最初の向きに戻った時点で自動終了して結果を出します。")
    print(calLimit > 0 ? "（\(Int(calLimit)) 秒で打ち切り。Ctrl-C でも即出力）" : "（Ctrl-C で即出力）")
    print("")

    signal(SIGINT, SIG_IGN)
    let calSig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    calSig.setEventHandler { cal.report(); exit(0) }
    calSig.resume()

    // 1 周した時点で完了。取りこぼしを拾うため少しだけ待ってから出力する。
    cal.onCycleComplete = {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { cal.report(); exit(0) }
    }
    if calLimit > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + calLimit) { cal.report(); exit(0) }
    }
    CFRunLoopRun()

case "test":
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let hud = HUD(config: config.hud)
    let sampleDPI = dpiTitle(CodedValue(code: 2, value: 2))
    var shots: [HUDContent] = [
        HUDContent(title: "Layer 2", subtitle: layerName(2), angle: 0,
                   meta: [angleName(0), sampleDPI], connection: Connection.usb.symbol),
        HUDContent(title: "OctaShift", subtitle: angleName(90), angle: 90,
                   meta: [layerName(2), sampleDPI], connection: Connection.bluetooth.symbol),
        HUDContent(title: "DPI", subtitle: sampleDPI, angle: 225,
                   meta: [layerName(5), angleName(225)], connection: Connection.dongle.symbol),
        HUDContent(title: "OctaShift", subtitle: "コード 0x2D（未校正）", angle: nil,
                   meta: [layerName(3), sampleDPI], connection: Connection.usb.symbol),
    ]
    func next() {
        guard !shots.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + config.hud.seconds + 0.6) { exit(0) }
            return
        }
        hud.show(shots.removeFirst())
        DispatchQueue.main.asyncAfter(deadline: .now() + config.hud.seconds + 0.5) { next() }
    }
    DispatchQueue.main.async { next() }
    app.run()

case "run":
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // Dock に出さない常駐プロセス

    let hud = HUD(config: config.hud)
    let decoder = StateDecoder(rules: config.rules)
    let mon = HIDMonitor(match: config.device)

    var lastContent: HUDContent?
    let status: StatusItemController? = config.hud.showMenuBarIcon
        ? StatusItemController(showsLayerBadge: config.hud.menuBarShowsLayer)
        : nil

    /// メニューバーの表示を現在値に合わせる
    func refreshStatus() {
        guard let status else { return }
        let st = decoder.state
        let headline = st.layer.map { "Layer \(displayLayer($0)) — \(layerName($0))" } ?? "レイヤー 未検出"
        let detail = [st.angle.map(angleTitle), st.dpi.map(dpiTitle)]
            .compactMap { $0 }.joined(separator: "   ·   ")
        let conn = mon.interfaceSummary.isEmpty ? nil : mon.activeConnection.symbol
        status.update(headline: headline, detail: detail, connection: conn,
                      layerBadge: st.layer.map(String.init))
    }

    func present(_ change: StateChange, connection: Connection) {
        let conn = config.hud.showConnection ? connection.symbol : nil
        let st = decoder.state
        // 主役以外の現在値を補助行に並べる（存在するものだけ）
        let layerMeta = st.layer.map { layerName($0) }
        let angleMeta = st.angle.map(angleTitle)
        let dpiMeta = st.dpi.map(dpiTitle)
        let content: HUDContent?

        switch change {
        case .layerPrimary(let l):
            // レイヤー切替ボタン: レイヤーを主役
            content = HUDContent(
                title: "Layer \(displayLayer(l))",
                subtitle: layerName(l),
                angle: st.angle?.value,
                meta: [angleMeta, dpiMeta].compactMap { $0 },
                connection: conn)

        case .anglePrimary(let a):
            // 8 方向切替ボタン: 角度を主役
            content = HUDContent(
                title: "OctaShift",
                subtitle: angleTitle(a),
                angle: a.value,
                meta: [layerMeta, dpiMeta].compactMap { $0 },
                connection: conn)

        case .dpiPrimary(let d):
            // DPI 切替ボタン: DPI を主役
            content = HUDContent(
                title: "DPI",
                subtitle: dpiTitle(d),
                angle: st.angle?.value,
                meta: [layerMeta, angleMeta].compactMap { $0 },
                connection: conn)

        case .repeatLast:
            // 値は変わらなかったがボタンは押された → 直前の表示を出し直す
            content = lastContent
        }

        guard let c = content else { return }
        lastContent = c
        hud.show(c)
        refreshStatus()
    }

    decoder.onUnmapped = { field, raw, bytes in
        let how = field == "向き"
            ? "`nape-hud calibrate` で angle の map に追加してください。"
            : "config.json の rules[].dpi.map に段 \(raw) の DPI 値を追加してください。"
        FileHandle.standardError.write("""
            ⚠️  対応表に無い\(field)の値 0x\(String(format: "%02X", raw)) (\(raw)) を受信しました。
                レポート: \(hexDump(bytes))
                \(how)

            """.data(using: .utf8)!)
        // アプリとして常駐しているときは標準エラーが見えないので、メニューにも出す
        status?.showWarning("\(field)の値 0x\(String(format: "%02X", raw)) が未設定です")
    }
    if debug {
        decoder.onMatched = { rule, bytes, state in
            func show(_ c: CodedValue?, _ unit: String) -> String {
                guard let c else { return "-" }
                guard let v = c.value else { return String(format: "0x%02X 未校正", c.code) }
                return "\(v)\(unit) (0x\(String(format: "%02X", c.code)))"
            }
            let l = state.layer.map(String.init) ?? "-"
            print("[\(rule.name)] \(hexDump(bytes))  → layer=\(l)"
                  + " angle=\(show(state.angle, "°")) dpi=\(show(state.dpi, ""))")
        }
    }
    // 校正中はここに差し替える。通常の HUD を止めないとボタンを押すたびに邪魔になる。
    var calibration: CalibrationController?

    mon.onReport = { ev in
        if let cal = calibration, cal.isActive {
            cal.ingest(ev)
            return
        }
        if let change = decoder.ingest(ev) { present(change, connection: ev.connection) }
    }
    mon.onConnectionChange = { conn, connected, product in
        FileHandle.standardError.write("\(connected ? "接続" : "切断"): \(product) [\(conn.rawValue)]\n"
            .data(using: .utf8)!)
        if connected {
            // 接続方式が変わったら状態は不明になるので作り直す。
            decoder.reset()
            status?.showWarning(nil)
        }
        refreshStatus()
        guard config.hud.showOnConnectionChange else { return }
        hud.show(HUDContent(title: "Nape Pro",
                            subtitle: "\(connected ? "接続" : "切断"): \(conn.rawValue)",
                            angle: nil, connection: connected ? conn.symbol : nil))
    }

    // メニューバーの各操作
    status?.onShowNow = {
        if let c = lastContent { hud.show(c) } else {
            hud.show(HUDContent(title: "Nape Pro",
                                subtitle: mon.interfaceSummary.isEmpty ? "未接続" : "状態 未検出",
                                angle: nil,
                                meta: ["ボタンを押すと検出されます"],
                                connection: mon.interfaceSummary.isEmpty ? nil
                                    : mon.activeConnection.symbol))
        }
    }
    status?.onTest = {
        hud.show(HUDContent(title: "Layer 3", subtitle: layerName(3), angle: 90,
                            meta: [angleName(90), dpiTitle(CodedValue(code: 2, value: 1600))],
                            connection: mon.activeConnection.symbol))
    }
    // キーアサイン表示。窓は開いている間だけ保持する。
    var keymapWindow: KeymapController?
    status?.onShowKeymap = {
        if let w = keymapWindow { w.show(); return }
        let w = KeymapController(match: config.device,
                                 settings: config.keymap,
                                 layerName: layerNameByNumber)
        w.onClose = { keymapWindow = nil }
        keymapWindow = w
        w.show()
    }
    status?.onCalibrate = {
        // 既に開いていれば前面に出すだけ
        if let cal = calibration, cal.isActive { cal.begin(); return }

        let url = configPath ?? Config.defaultPath
        let cal = CalibrationController(rules: config.rules, settings: config.calibration, configURL: url)
        guard cal.hasAngleRule else {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "校正できません"
            a.informativeText = """
                設定の rules に angle フィールドを持つルールがありません。
                先に `nape-hud learn` でレポート形式を特定してください。
                """
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "設定ファイルがありません"
            a.informativeText = """
                \(url.path) が見つかりません。
                config.example.json をこの場所にコピーしてから校正してください。
                """
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            return
        }
        cal.onClose = { needsRestart in
            calibration = nil
            decoder.reset()          // 校正中の入力で状態がずれているため作り直す
            refreshStatus()
            if needsRestart { status?.onRelaunch?() }
        }
        calibration = cal
        cal.begin()
    }
    status?.onOpenConfig = {
        let url = configPath ?? Config.defaultPath
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            // 未作成なら置き場所を開いて、どこに作ればよいか分かるようにする
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
    status?.onRelaunch = {
        // 設定は起動時に読み込むだけなので、確実に反映させるには自分を作り直す。
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: cfg) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } else {
            // バンドル外（ターミナル実行）では自分を exec し直す
            let exe = URL(fileURLWithPath: CommandLine.arguments[0])
            let p = Process()
            p.executableURL = exe
            p.arguments = Array(CommandLine.arguments.dropFirst())
            try? p.run()
            NSApp.terminate(nil)
        }
    }

    // 一致するデバイスが 0xFF60（状態通知の面）を持たない接続方式だと、
    // 監視は成功するのにイベントが一切来ない = 何も起きない状態になる。
    // 黙って動かないのが一番困るので、起動時に気づけるようにする。
    // enumerateAll はデバイスを開かないので追加の許可は不要。
    func warnIfConnectionCannotReport() {
        let all = HIDMonitor.enumerateAll().filter {
            config.device.matches(vid: $0.vendorId, pid: $0.productId, product: $0.product)
        }
        guard !all.isEmpty else { return }
        let pages = config.device.usagePages
        let byDevice = Dictionary(grouping: all) { "\($0.productId)-\($0.product)-\($0.transport)" }
        let blind = byDevice.values.filter { ifaces in
            !ifaces.contains { $0.usagePage == 0xFF60 && (pages.isEmpty || pages.contains($0.usagePage)) }
        }
        let capableCount = byDevice.values.count - blind.count
        guard let first = blind.first?.first else { return }

        let name = "\(first.product) [\(first.transport)]"
        let hint = capableCount > 0
            ? "有線 / 2.4GHz ドングル経由なら検出できます。"
            : "有線 / 2.4GHz ドングルを使うか、keyFallback を有効にしてください。"
        let msg = "⚠️  \(name) は状態通知の面（0xFF60）を持たないため、この経路では検出できません。\n"
            + "    \(hint)\n"
            + "    詳細は `nape-hud devices` で確認できます。\n\n"
        FileHandle.standardError.write(msg.data(using: .utf8)!)
        status?.showWarning("\(first.transport) では検出できません")
    }
    warnIfConnectionCannotReport()

    do {
        try mon.start()
    } catch {
        // アプリとして起動しているとターミナルの出力が見えないので、必ず画面に出す。
        FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "デバイスの監視を開始できませんでした"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "入力監視の設定を開く")
        alert.addButton(withTitle: "終了")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            _ = requestInputMonitoring()
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(u)
            }
        }
        exit(1)
    }
    refreshStatus()

    // センチネルキー経路
    if config.keyFallback.enabled {
        if !KeyWatcher.accessibilityGranted { KeyWatcher.promptAccessibility() }
        let watcher = KeyWatcher(fallback: config.keyFallback)
        watcher.onMatch = { layer, angle, dpi in
            if let change = decoder.apply(layer: layer, angleDegrees: angle, dpi: dpi) {
                present(change, connection: mon.activeConnection)
            }
        }
        do { try watcher.start() } catch {
            FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }

    // ポインタ加速（任意機能・既定は無効）
    //
    // 起動時だけでなく設定画面からも呼ばれる。ここで生成・破棄まで面倒を見ないと
    // 「実行中に有効にしても加速器が無いまま」になる（実際にその不具合を出した）。
    var accelerator: PointerAccelerator?
    var trackballMonitor: HIDMonitor?
    var lastTrackballMotion = Date.distantPast

    /// 加速の設定を適用する。戻り値は利用者に見せる状態文言。
    @discardableResult
    func applyAcceleration(_ accel: AccelerationConfig, announce: Bool = true) -> AccelerationStatus {
        func teardown() {
            accelerator?.stop()
            accelerator = nil
            trackballMonitor?.stop()
            trackballMonitor = nil
        }

        guard accel.enabled else {
            teardown()
            status?.setAcceleration(enabled: false)
            status?.showWarning(nil)
            return .init(running: false, message: "停止中（設定で無効）")
        }

        guard KeyWatcher.accessibilityGranted else {
            teardown()
            KeyWatcher.promptAccessibility()
            status?.setAcceleration(enabled: false)
            status?.showWarning("ポインタ加速: アクセシビリティ未許可")
            return .init(running: false,
                         message: "停止中: アクセシビリティが未許可",
                         permission: .accessibility)
        }

        // トラックボール由来だけに効かせるには、その動きを HID 側で見る必要がある。
        // ポインタ面（usage page 1）の監視には「入力監視」の許可がいる。
        if accel.onlyTrackball {
            guard inputMonitoringGranted() else {
                teardown()
                _ = requestInputMonitoring()
                status?.setAcceleration(enabled: false)
                status?.showWarning("ポインタ加速: 入力監視が未許可のため停止中")
                return .init(running: false,
                             message: "停止中: 入力監視が未許可（許可しないと内蔵トラックパッドにも効いてしまうため）",
                             permission: .inputMonitoring)
            }
            if trackballMonitor == nil {
                let tb = HIDMonitor(match: config.device, allUsagePages: true)
                tb.onReport = { ev in
                    // ポインタ/キーボード面のレポート = 本体を操作している
                    if ev.usagePage == 0x01 { lastTrackballMotion = Date() }
                }
                do {
                    try tb.start()
                    trackballMonitor = tb
                } catch {
                    teardown()
                    status?.setAcceleration(enabled: false)
                    status?.showWarning("ポインタ加速: 本体の監視に失敗")
                    return .init(running: false, message: "停止中: 本体の動きを監視できません")
                }
            }
        } else {
            trackballMonitor?.stop()
            trackballMonitor = nil
        }

        if accelerator == nil {
            let a = PointerAccelerator(config: accel)
            a.debug = debug
            a.isTrackballActive = {
                let window = Double(accel.trackballActiveWindowMs) / 1000
                return Date().timeIntervalSince(lastTrackballMotion) < window
            }
            a.currentLayer = { decoder.state.layer }
            do {
                try a.start()
                accelerator = a
            } catch {
                teardown()
                status?.setAcceleration(enabled: false)
                status?.showWarning("ポインタ加速を開始できませんでした")
                return .init(running: false, message: "停止中: \(error.localizedDescription)",
                             permission: .accessibility)
            }
        }
        accelerator?.update(accel)
        status?.setAcceleration(enabled: true)
        status?.showWarning(nil)

        let scope = accel.onlyTrackball ? "Nape Pro のみ" : "全ポインタ"
        let msg = "動作中（\(accel.baseGain)x → \(accel.maxGain)x"
            + " / \(Int(accel.thresholdSpeed))〜\(Int(accel.fullSpeed)) px/s / \(scope)）"
        if announce {
            FileHandle.standardError.write("ポインタ加速: \(msg)\n".data(using: .utf8)!)
        }
        return .init(running: true, message: msg)
    }

    applyAcceleration(config.acceleration)

    status?.onToggleAcceleration = {
        guard let a = accelerator else { return false }
        a.isEnabled.toggle()
        return a.isEnabled
    }

    // 設定画面。加速の値だけは動かしながら調整できるよう即時反映する。
    var settingsWindow: SettingsController?
    status?.onOpenSettings = {
        if let w = settingsWindow { w.show(); return }
        let w = SettingsController(config: config, configURL: configPath ?? Config.defaultPath)
        // 生成・破棄まで含めて適用する（起動時と同じ経路）
        w.onAccelerationChanged = { newAccel in applyAcceleration(newAccel, announce: false) }
        w.onLayerNamesChanged = { names in
            layerNameOverride = names
            refreshStatus()
            // 直前の表示にも新しい名前を反映して出し直す
            if let l = decoder.state.layer {
                present(.layerPrimary(l), connection: mon.activeConnection)
            }
        }
        w.onOpenConfigFile = { status?.onOpenConfig?() }
        w.onRequestRestart = { status?.onRelaunch?() }
        w.onClose = { settingsWindow = nil }
        settingsWindow = w
        w.show()
        // 開いた時点の実際の動作状況を見せる
        w.showInitialAccelerationStatus(applyAcceleration(config.acceleration, announce: false))
    }

    // 自発通知しないファーム向けの定期問い合わせ
    if config.poll.enabled, !config.poll.request.isEmpty {
        Timer.scheduledTimer(withTimeInterval: Double(config.poll.intervalMs) / 1000, repeats: true) { _ in
            mon.send(usagePage: config.poll.usagePage, usage: config.poll.usage,
                     reportId: config.poll.reportId, bytes: config.poll.request.map { UInt8($0 & 0xFF) })
        }
    }

    if config.rules.isEmpty && !config.keyFallback.enabled {
        FileHandle.standardError.write("""
            ⚠️  rules も keyFallback も未設定です。状態変化を検出できません。
                まず Keychron Launcher を閉じ、`nape-hud learn` でレポート形式を特定してください。

            """.data(using: .utf8)!)
    }

    app.run()

default:
    usage()
    exit(2)
}
