using System.Text;

namespace NapeHud;

public static class Program
{
    static Config _cfg = new();
    static string _cfgPath = "";
    static bool _verbose;

    public static int Main(string[] argv)
    {
        Console.OutputEncoding = Encoding.UTF8;

        var mode = argv.Length > 0 && !argv[0].StartsWith('-') ? argv[0] : "run";
        string? cfgPath = null;
        double seconds = 0;
        bool secondsGiven = false;

        for (int i = (mode == argv.FirstOrDefault() ? 1 : 0); i < argv.Length; i++)
        {
            switch (argv[i])
            {
                case "-c" or "--config": if (++i < argv.Length) cfgPath = argv[i]; break;
                case "-s" or "--seconds":
                    if (++i < argv.Length && double.TryParse(argv[i], out var d)) { seconds = d; secondsGiven = true; }
                    break;
                case "-v" or "--verbose": _verbose = true; break;
                case "-h" or "--help": mode = "help"; break;
                default:
                    Console.Error.WriteLine($"不明なオプション: {argv[i]}");
                    return 2;
            }
        }

        try
        {
            _cfg = Config.Load(cfgPath, out _cfgPath);
        }
        catch (AppError e) { Console.Error.WriteLine(e.Message); return 1; }

        try
        {
            switch (mode)
            {
                case "help": Usage(); return 0;
                case "devices": return Devices();
                case "run": return Run();
                case "sniff": return Sniff(secondsGiven ? seconds : 90);
                case "keymap": return Keymap();
                case "selftest": return SelfTest();
                default: Usage(); return 2;
            }
        }
        catch (AppError e) { Console.Error.WriteLine(e.Message); return 1; }
    }

    static void Usage() => Console.WriteLine("""
        nape-hud (Windows CLI) — Keychron Nape Pro のレイヤー / 向き / DPI を表示

        使い方:
          nape-hud [run]      状態の変化を出力し続ける（Ctrl-C で終了）
          nape-hud devices    HID デバイスを列挙し、照合結果と不一致の理由を出す
          nape-hud sniff      生の HID レポートを観測する
          nape-hud keymap     登録されたキーアサインを読み出す（VIA プロトコル）
          nape-hud selftest   合成レポートで復号経路を検証する（デバイス不要）

        オプション:
          -c, --config <path>  設定ファイル
          -s, --seconds <n>    sniff の観測秒数（既定 90、0 で無制限）
          -v, --verbose        詳細表示

        設定ファイルの探索順:
          -c で指定 → %APPDATA%\nape-hud\config.json → 実行ファイルと同じ場所
        """);

    // MARK: devices

    static int Devices()
    {
        Console.WriteLine("nape-hud devices — HID デバイスの一覧と照合結果");
        Console.WriteLine();
        Console.WriteLine("設定ファイル: " + _cfgPath);
        Console.WriteLine("照合条件:");
        Console.WriteLine($"  vendorId            : 0x{_cfg.Device.VendorId:X4}");
        Console.WriteLine("  productIds          : " + string.Join(", ", _cfg.Device.ProductIds.Select(p => $"0x{p:X4}")));
        Console.WriteLine("  productNameContains : " + string.Join(", ", _cfg.Device.ProductNameContains));
        var pages = _cfg.Device.UsagePages;
        Console.WriteLine("  usagePages（監視面）: " + (pages.Count == 0 ? "全面" : string.Join(", ", pages.Select(p => $"0x{p:X4}"))));
        Console.WriteLine();

        var all = WinHid.Enumerate();
        if (all.Count == 0) { Console.WriteLine("HID デバイスを列挙できませんでした。"); return 1; }

        var groups = all.GroupBy(d => $"{d.VendorId}-{d.ProductId}-{d.Product}");
        bool matchedAny = false;
        var capable = new List<string>();
        var incapable = new List<string>();

        foreach (var g in groups.OrderBy(g => g.Key))
        {
            var ifaces = g.OrderBy(d => d.UsagePage).ToList();
            var first = ifaces[0];
            bool matches = _cfg.Device.Matches(first.VendorId, first.ProductId, first.Product);
            bool interesting = first.VendorId == _cfg.Device.VendorId
                || _cfg.Device.ProductNameContains.Any(s => s.Length > 0 &&
                       first.Product.Contains(s, StringComparison.OrdinalIgnoreCase));
            if (!interesting && !matches) continue;

            Console.WriteLine($"{(matches ? "✅ 一致" : "❌ 不一致")}  {(first.Product.Length == 0 ? "(名称なし)" : first.Product)}");
            Console.WriteLine($"   VID/PID : 0x{first.VendorId:X4} / 0x{first.ProductId:X4}");
            Console.WriteLine("   インターフェース:");
            foreach (var i in ifaces)
            {
                bool watched = pages.Count == 0 || pages.Contains(i.UsagePage);
                var note = i.UsagePage == 0xFF60 ? "  ← 状態通知が来る面" : "";
                Console.WriteLine($"     0x{i.UsagePage:X4}/0x{i.Usage:X2}  in={i.InputReportLength}B  "
                                  + (watched ? "監視対象" : "監視対象外") + note);
            }

            if (matches)
            {
                matchedAny = true;
                bool hasVendor = ifaces.Any(i => i.UsagePage == 0xFF60
                                                 && (pages.Count == 0 || pages.Contains(i.UsagePage)));
                if (hasVendor) capable.Add(first.Product);
                else incapable.Add(first.Product);
            }
            else
            {
                var why = new List<string>();
                if (first.VendorId != _cfg.Device.VendorId) why.Add("vendorId が違う");
                if (!_cfg.Device.ProductIds.Contains(first.ProductId))
                    why.Add($"productIds に 0x{first.ProductId:X4} が無い");
                if (!_cfg.Device.ProductNameContains.Any(s => s.Length > 0 &&
                        first.Product.Contains(s, StringComparison.OrdinalIgnoreCase)))
                    why.Add("productNameContains に一致する語が無い");
                Console.WriteLine("   不一致の理由: " + string.Join(" / ", why));
                Console.WriteLine($"   → 対処: config.json の device.productIds に 0x{first.ProductId:X4} を追加");
            }
            Console.WriteLine();
        }

        Console.WriteLine("── 判定 ──");
        if (!matchedAny)
        {
            Console.WriteLine("❌ 照合条件に一致するデバイスがありません。");
            Console.WriteLine("   上記の「不一致の理由」と対処を確認してください。");
            return 1;
        }
        if (capable.Count > 0)
        {
            Console.WriteLine("✅ 状態通知を受け取れる経路:");
            capable.ForEach(n => Console.WriteLine($"     {n}"));
        }
        if (incapable.Count > 0)
        {
            Console.WriteLine("❌ 状態通知を受け取れない経路（0xFF60 の面が無い）:");
            incapable.ForEach(n => Console.WriteLine($"     {n}"));
            Console.WriteLine("   この経路で操作している間は検出できません。");
            Console.WriteLine("   → 対処: USB 有線 / 2.4GHz ドングルを使う（Bluetooth では検出できません）");
        }
        return capable.Count > 0 ? 0 : 1;
    }

    // MARK: 監視の共通部分

    /// <summary>Core の DeviceMonitor に委譲する。GUI 版と同じ読み取り経路を使う。</summary>
    static DeviceMonitor ReadReports(DeviceMonitor.ReportHandler onReport, CancellationToken token)
    {
        var mon = new DeviceMonitor(_cfg, onReport, token);
        foreach (var t in mon.Targets)
            Console.Error.WriteLine($"監視: {t.Product} 0x{t.UsagePage:X4}/0x{t.Usage:X2} in={t.InputReportLength}B");
        foreach (var f in mon.Failures) Console.Error.WriteLine("開けません: " + f);
        return mon;
    }

    static int Run()
    {
        var decoder = new StateDecoder(_cfg.Rules);
        decoder.OnUnmapped = (field, raw, bytes) =>
            Console.Error.WriteLine($"⚠️  対応表に無い{field}の値 0x{raw:X2} ({raw})  レポート: {Fmt.Hex(bytes)}");

        using var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };

        string last = "";
        ReadReports((dev, reportId, bytes) =>
        {
            var ch = decoder.Ingest(dev.UsagePage, dev.Usage, reportId, bytes);
            if (ch == null) return;
            var s = decoder.State;
            string line = ch.Value.Kind switch
            {
                ChangeKind.LayerPrimary =>
                    $"Layer {ch.Value.Layer + _cfg.LayerNumberOffset}  {_cfg.LayerName(ch.Value.Layer)}",
                ChangeKind.AnglePrimary => $"OctaShift  {AngleText(ch.Value.Value)}",
                ChangeKind.DpiPrimary => $"DPI  {DpiText(ch.Value.Value)}",
                _ => last,
            };
            if (line.Length == 0) return;
            last = line;
            var meta = new List<string>();
            if (s.Layer.HasValue) meta.Add(_cfg.LayerName(s.Layer.Value));
            if (s.Angle.HasValue) meta.Add(AngleText(s.Angle.Value));
            if (s.Dpi.HasValue) meta.Add(DpiText(s.Dpi.Value));
            Console.WriteLine($"[{DateTime.Now:HH:mm:ss}] {line}"
                              + (meta.Count > 0 ? "   （" + string.Join(" · ", meta) + "）" : ""));
        }, cts.Token);

        Console.Error.WriteLine("状態の変化を待っています（Ctrl-C で終了）");
        cts.Token.WaitHandle.WaitOne();
        return 0;
    }

    static int Sniff(double seconds)
    {
        using var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };
        var seen = new Dictionary<string, byte[]>();
        var start = DateTime.Now;

        ReadReports((dev, reportId, bytes) =>
        {
            var key = $"{dev.UsagePage:X4}-{reportId:X2}-{bytes.Length}-{(bytes.Length > 0 ? bytes[0] : 0):X2}";
            bool isNew = !seen.ContainsKey(key);
            var changed = new List<int>();
            if (!isNew)
            {
                var prev = seen[key];
                for (int i = 0; i < Math.Min(prev.Length, bytes.Length); i++)
                    if (prev[i] != bytes[i]) changed.Add(i);
            }
            seen[key] = (byte[])bytes.Clone();
            if (!isNew && changed.Count == 0 && !_verbose) return;

            var sb = new StringBuilder();
            for (int i = 0; i < bytes.Length; i++)
                sb.Append(changed.Contains(i) ? $"[{bytes[i]:X2}]" : $" {bytes[i]:X2} ");
            Console.WriteLine($"[{(DateTime.Now - start).TotalSeconds,7:F3}] 0x{dev.UsagePage:X4} len={bytes.Length}  {sb}");
        }, cts.Token);

        Console.Error.WriteLine(seconds > 0
            ? $"観測中（{seconds:F0} 秒で自動終了 / Ctrl-C でも終了）"
            : "観測中（Ctrl-C で終了）");
        if (seconds > 0) cts.Token.WaitHandle.WaitOne(TimeSpan.FromSeconds(seconds));
        else cts.Token.WaitHandle.WaitOne();
        return 0;
    }

    static int Keymap()
    {
        var dev = WinHid.Enumerate()
            .Where(d => _cfg.Device.Matches(d.VendorId, d.ProductId, d.Product))
            .FirstOrDefault(d => d.UsagePage == 0xFF60);
        if (dev == null)
            throw new AppError("raw HID (0xFF60) のインターフェースが見つかりません。\n"
                + "Bluetooth 接続ではベンダ面が出ないため読み出せません。USB / 2.4GHz を使ってください。");

        using var via = new ViaClient(dev);
        var snap = via.ReadSnapshot(_cfg.Keymap);
        Console.WriteLine(KeymapReport.Text(snap, _cfg));
        return 0;
    }

    // MARK: selftest（デバイス不要。macOS 版と同じ検証をする）

    static int SelfTest()
    {
        int failures = 0;
        var rule = _cfg.Rules.FirstOrDefault(r => r.Layer != null || r.Angle != null || r.Dpi != null);
        if (rule == null) { Console.WriteLine("rules が空です。config.json を確認してください。"); return 1; }

        int up = rule.UsagePage ?? 0xFF60, us = rule.Usage ?? 0x61;
        byte cmd = (byte)(rule.Match?.FirstOrDefault(m => m.Offset == 0)?.Equals_?.FirstOrDefault() ?? 0xA3);

        byte[] Synth(byte layer, byte dir, byte dpi)
        {
            var b = new byte[32];
            b[0] = cmd; b[1] = layer; b[2] = dir; b[3] = dpi;
            return b;
        }

        Console.WriteLine($"設定ファイル: {_cfgPath}");
        Console.WriteLine($"ルール: {(rule.Name.Length == 0 ? "(無名)" : rule.Name)}");
        Console.WriteLine($"cmd=0x{cmd:X2} layer.offset={rule.Layer?.Offset.ToString() ?? "-"} "
                          + $"angle.offset={rule.Angle?.Offset.ToString() ?? "-"} "
                          + $"dpi.offset={rule.Dpi?.Offset.ToString() ?? "-"}");
        Console.WriteLine();

        var dec = new StateDecoder(_cfg.Rules);
        var steps = new (byte L, byte D, byte P, string Note)[]
        {
            (1, 3, 2, "初回受信"),
            (2, 3, 2, "レイヤーのみ 1→2"),
            (3, 3, 2, "レイヤーのみ 2→3"),
            (3, 4, 2, "向きのみ 3→4"),
            (3, 4, 2, "同じ値で再通知"),
            (3, 4, 3, "DPIのみ 2→3"),
            (3, 4, 0, "DPIのみ 3→0（巡回）"),
            (4, 5, 0, "レイヤーのみ・向き付随"),
        };
        foreach (var (L, D, P, note) in steps)
        {
            var ch = dec.Ingest(up, us, 0, Synth(L, D, P));
            string desc = ch == null ? "表示なし" : ch.Value.Kind switch
            {
                ChangeKind.LayerPrimary => $"レイヤー主役 → Layer {ch.Value.Layer} ({_cfg.LayerName(ch.Value.Layer)})",
                ChangeKind.AnglePrimary => $"角度主役 → {AngleText(ch.Value.Value)}",
                ChangeKind.DpiPrimary => $"DPI 主役 → {DpiText(ch.Value.Value)}",
                _ => "直前表示の再掲",
            };
            Console.WriteLine($"  {cmd:X2} {L:X2} {D:X2} {P:X2} …  {Fmt.Pad(note, 30)}{desc}");

            bool ok = note.StartsWith("レイヤーのみ") ? ch?.Kind == ChangeKind.LayerPrimary
                    : note.StartsWith("向きのみ") ? ch?.Kind == ChangeKind.AnglePrimary
                    : note.StartsWith("DPIのみ") ? ch?.Kind == ChangeKind.DpiPrimary
                    : true;
            if (!ok) { Console.WriteLine("    ❌ 期待した主役になっていません"); failures++; }
        }

        Console.WriteLine();
        Console.WriteLine(failures == 0
            ? "✅ 復号経路は正常。レイヤー / 向き / DPI の各バイトが変われば対応する表示になります。"
            : $"❌ {failures} 件の不整合。config.json のルールを見直してください。");
        return failures == 0 ? 0 : 1;
    }

    // MARK: 表示ヘルパ

    static string AngleText(CodedValue a) =>
        a.Value.HasValue ? _cfg.AngleName(a.Value.Value) : $"コード 0x{a.Code:X2}（未校正）";

    static string DpiText(CodedValue d) =>
        d.Value.HasValue ? _cfg.DpiName(d.Value.Value) : $"段 0x{d.Code:X2}（DPI 値 未設定）";

}
