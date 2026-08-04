using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace NapeHud;

/// <summary>
/// 通知領域に常駐し、レイヤー / OctaShift の向き / DPI が変わったら
/// 画面の隅にポップアップを出す。CLI 版と同じ config.json と復号コードを使う。
/// </summary>
public static class GuiProgram
{
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr handle);

    static Config _cfg = new();
    static string _cfgPath = "";
    static HudWindow _hud = null!;
    static NotifyIcon _tray = null!;
    static StateDecoder _decoder = null!;
    static CancellationTokenSource _cts = new();
    static DeviceMonitor? _monitor;
    static string _monitorKey = "";       // 監視中の面の一覧。変化を見て貼り直す
    static string _lastTrouble = "";      // 同じ警告を出し続けないため
    static HudContent _last = new("", "", null);   // 再通知で出し直す用
    static Icon? _trayIcon;
    static readonly System.Windows.Forms.Timer _watch = new() { Interval = 3000 };

    [STAThread]
    public static int Main(string[] argv)
    {
        string? cfgPath = null;
        bool demo = false;
        for (int i = 0; i < argv.Length; i++)
        {
            switch (argv[i])
            {
                case "-c" or "--config": if (++i < argv.Length) cfgPath = argv[i]; break;
                case "--test": demo = true; break;
                case "-h" or "--help":
                    MessageBox.Show(
                        "nape-hud-gui — Keychron Nape Pro の状態をポップアップで表示\n\n"
                        + "  -c <path>   設定ファイルを指定\n"
                        + "  --test      起動時に表示テストを行う\n\n"
                        + "常駐アイコンの右クリックから操作します。\n"
                        + "コンソールで使う場合は nape-hud.exe（CLI 版）を使ってください。",
                        "nape-hud-gui", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return 0;
            }
        }

        // DPI の扱いは csproj の ApplicationHighDpiMode で指定している。
        // Initialize より後に SetHighDpiMode を呼んでも効かない。
        ApplicationConfiguration.Initialize();

        try { _cfg = Config.Load(cfgPath, out _cfgPath); }
        catch (AppError e)
        {
            MessageBox.Show(e.Message, "nape-hud", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        if (_cfg.Rules.Count == 0)
        {
            MessageBox.Show(
                "設定に rules がありません。状態を読み取れないため終了します。\n\n"
                + "設定ファイル: " + _cfgPath,
                "nape-hud", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        _decoder = new StateDecoder(_cfg.Rules);
        _hud = new HudWindow(_cfg);
        _ = _hud.Handle;      // 先にハンドルを作る。作る前は BeginInvoke できない

        BuildTray();
        UpdateTrayIcon(null);

        _watch.Tick += (_, _) => EnsureMonitor();
        _watch.Start();
        EnsureMonitor();

        if (demo) _hud.Present(new HudContent("表示テスト", "この位置に出ます", 45));

        Application.Run(new ApplicationContext());

        _cts.Cancel();
        _monitor?.Dispose();
        _tray.Visible = false;
        _tray.Dispose();
        _trayIcon?.Dispose();
        return 0;
    }

    // MARK: 常駐アイコン

    static void BuildTray()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("現在の状態を表示", null, (_, _) => ShowCurrent());
        menu.Items.Add("キーアサインを表示…", null, (_, _) => ShowKeymap());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("接続状況…", null, (_, _) => ShowStatus());
        menu.Items.Add("設定ファイルを開く", null, (_, _) => OpenConfig());
        menu.Items.Add("設定を読み込み直す", null, (_, _) => ReloadConfig());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("終了", null, (_, _) => Application.Exit());

        _tray = new NotifyIcon
        {
            Text = "nape-hud",
            Visible = _cfg.Hud.ShowMenuBarIcon,
            ContextMenuStrip = menu,
        };
        _tray.DoubleClick += (_, _) => ShowCurrent();
    }

    /// <summary>常駐アイコンを描く。設定が有効なら現在のレイヤー番号を添える。</summary>
    static void UpdateTrayIcon(int? layerNumber)
    {
        var old = _trayIcon;
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.Transparent);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
            using var pen = new Pen(Color.White, 2.4f);
            g.DrawEllipse(pen, 2.5f, 2.5f, 27, 27);
            if (layerNumber.HasValue && _cfg.Hud.MenuBarShowsLayer)
            {
                var s = layerNumber.Value.ToString();
                using var f = new Font("Segoe UI", 17, FontStyle.Bold, GraphicsUnit.Pixel);
                var sz = g.MeasureString(s, f);
                g.DrawString(s, f, Brushes.White, (32 - sz.Width) / 2, (32 - sz.Height) / 2);
            }
        }
        var h = bmp.GetHicon();
        try { _trayIcon = (Icon)Icon.FromHandle(h).Clone(); }
        finally { DestroyIcon(h); }   // Clone で複製済みなので元のハンドルは捨てる
        _tray.Icon = _trayIcon;
        old?.Dispose();
    }

    // MARK: 監視の維持

    /// <summary>
    /// 監視対象を数秒ごとに見張る。抜き差しや接続方式の切り替えで
    /// 面の構成が変わるので、変わったら貼り直す。
    /// </summary>
    static void EnsureMonitor()
    {
        string key;
        try
        {
            var pages = _cfg.Device.UsagePages;
            key = string.Join("|", WinHid.Enumerate()
                .Where(d => _cfg.Device.Matches(d.VendorId, d.ProductId, d.Product))
                .Where(d => pages.Count == 0 || pages.Contains(d.UsagePage))
                .Where(d => d.InputReportLength > 0)
                .Select(d => d.Path)
                .OrderBy(p => p));
        }
        catch { return; }

        if (_monitor != null && key == _monitorKey) return;   // 変化なし

        _monitor?.Dispose();
        _monitor = null;
        _monitorKey = key;
        // Dispose はしない。読み取りスレッドが破棄済みのトークンを見ると例外になる。
        _cts.Cancel();
        _cts = new CancellationTokenSource();

        if (key.Length == 0)
        {
            Trouble("デバイスが見つかりません",
                "USB 有線か 2.4GHz ドングルで接続してください。\n"
                + "Bluetooth 接続では状態を検出できません。");
            UpdateTrayIcon(null);
            return;
        }

        try
        {
            _monitor = new DeviceMonitor(_cfg, OnReport, _cts.Token);
            if (!_monitor.HasVendorInterface)
                Trouble("状態通知の経路がありません",
                    "ベンダ面（0xFF60）を持つインターフェースが見つかりません。\n"
                    + "Bluetooth 接続では検出できません。USB 有線か 2.4GHz ドングルを使ってください。");
            else
                _lastTrouble = "";      // 復帰したので次の異常は改めて知らせる
        }
        catch (AppError e) { Trouble("監視を開始できません", e.Message); }
    }

    /// <summary>同じ内容の警告を繰り返さない。</summary>
    static void Trouble(string title, string body)
    {
        var key = title + body;
        _tray.Text = Truncate("nape-hud — " + title, 63);   // Text は 63 文字まで
        if (_lastTrouble == key) return;
        _lastTrouble = key;
        _tray.ShowBalloonTip(8000, title, body, ToolTipIcon.Warning);
    }

    // MARK: レポートの受信

    /// <summary>HID の読み取りスレッドから呼ばれる。UI 操作は必ず UI スレッドへ渡す。</summary>
    static void OnReport(WinHid.DeviceInfo dev, byte reportId, byte[] bytes)
    {
        var change = _decoder.Ingest(dev.UsagePage, dev.Usage, reportId, bytes);
        if (change == null) return;
        var st = _decoder.State;
        try { _hud.BeginInvoke(() => Render(change.Value, st)); }
        catch (InvalidOperationException) { /* 終了処理中 */ }
    }

    static void Render(StateChange ch, DeviceState st)
    {
        string big, sub;
        int? dialAngle = st.Angle?.Value;

        switch (ch.Kind)
        {
            case ChangeKind.LayerPrimary:
                big = $"Layer {ch.Layer + _cfg.LayerNumberOffset}";
                sub = _cfg.LayerName(ch.Layer);
                if (sub == big) sub = "";
                UpdateTrayIcon(ch.Layer + _cfg.LayerNumberOffset);
                break;
            case ChangeKind.AnglePrimary:
                big = AngleText(ch.Value);
                sub = "OctaShift";
                dialAngle = ch.Value.Value ?? dialAngle;
                break;
            case ChangeKind.DpiPrimary:
                big = DpiText(ch.Value);
                sub = "DPI";
                break;
            default:
                // 同じ値での再通知。直前に出したものをもう一度見せる
                if (_last.Big.Length > 0) _hud.Present(_last);
                return;
        }

        // 向き / DPI のときは、どのレイヤーでの変化かが分かるよう名前を添える
        if (st.Layer.HasValue && ch.Kind != ChangeKind.LayerPrimary)
            sub += $" · {_cfg.LayerName(st.Layer.Value)}";

        _tray.Text = Truncate("nape-hud — " + string.Join(" · ", Summary(st)), 63);
        _last = new HudContent(big, sub, dialAngle);
        _hud.Present(_last);
    }

    static IEnumerable<string> Summary(DeviceState st)
    {
        if (st.Layer.HasValue) yield return _cfg.LayerName(st.Layer.Value);
        if (st.Angle.HasValue) yield return AngleText(st.Angle.Value);
        if (st.Dpi.HasValue) yield return DpiText(st.Dpi.Value);
    }

    static string Truncate(string s, int max) => s.Length <= max ? s : s.Substring(0, max);

    static string AngleText(CodedValue a) =>
        a.Value.HasValue ? _cfg.AngleName(a.Value.Value) : $"コード 0x{a.Code:X2}（未校正）";

    static string DpiText(CodedValue d) =>
        d.Value.HasValue ? _cfg.DpiName(d.Value.Value) : $"段 0x{d.Code:X2}";

    // MARK: メニューの操作

    static void ShowCurrent()
    {
        var st = _decoder.State;
        if (!st.Layer.HasValue && !st.Angle.HasValue && !st.Dpi.HasValue)
        {
            _hud.Present(new HudContent("まだ受信していません",
                "レイヤーか向きを切り替えてください", null));
            return;
        }
        var big = st.Layer.HasValue
            ? $"Layer {st.Layer.Value + _cfg.LayerNumberOffset}" : "現在の状態";
        _hud.Present(new HudContent(big,
            string.Join(" · ", Summary(_decoder.State)), st.Angle?.Value));
    }

    static void ShowStatus()
    {
        var lines = new List<string>
        {
            "設定ファイル: " + _cfgPath,
            "",
            "照合条件:",
            $"  vendorId : 0x{_cfg.Device.VendorId:X4}",
            "  productIds : " + string.Join(", ", _cfg.Device.ProductIds.Select(p => $"0x{p:X4}")),
            "",
        };

        var all = WinHid.Enumerate();
        var mine = all.Where(d => _cfg.Device.Matches(d.VendorId, d.ProductId, d.Product)).ToList();
        if (mine.Count == 0)
            lines.Add("❌ 照合条件に一致するデバイスがありません。");
        else
            foreach (var g in mine.GroupBy(d => d.Product))
            {
                lines.Add($"✅ {(g.Key.Length == 0 ? "(名称なし)" : g.Key)}");
                foreach (var d in g.OrderBy(d => d.UsagePage))
                    lines.Add($"     0x{d.UsagePage:X4}/0x{d.Usage:X2}  in={d.InputReportLength}B"
                              + (d.UsagePage == 0xFF60 ? "   ← 状態通知が来る面" : ""));
            }

        lines.Add("");
        lines.Add(_monitor == null ? "監視: 停止中"
                 : "監視: " + string.Join(", ", _monitor.Targets.Select(t => $"0x{t.UsagePage:X4}")));
        if (_monitor != null && !_monitor.HasVendorInterface)
        {
            lines.Add("");
            lines.Add("⚠️ 0xFF60 の面を掴めていないため、状態は検出できません。");
            lines.Add("   Bluetooth 接続では原理的に検出できません（ベンダ面が宣言されていない）。");
            lines.Add("   USB 有線か 2.4GHz ドングルを使ってください。");
        }
        if (_monitor?.Failures.Count > 0)
        {
            lines.Add("");
            lines.Add("開けなかった面:");
            _monitor.Failures.ForEach(f => lines.Add("  " + f));
        }

        new TextWindow("接続状況 — nape-hud", string.Join("\n", lines)).Show();
    }

    static void ShowKeymap()
    {
        var dev = WinHid.Enumerate()
            .Where(d => _cfg.Device.Matches(d.VendorId, d.ProductId, d.Product))
            .FirstOrDefault(d => d.UsagePage == 0xFF60);
        if (dev == null)
        {
            MessageBox.Show(
                "raw HID (0xFF60) のインターフェースが見つかりません。\n"
                + "Bluetooth 接続では読み出せません。USB 有線か 2.4GHz ドングルを使ってください。",
                "nape-hud", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        // 数十回の往復があるので UI を止めないよう別スレッドで読む
        var wait = new TextWindow("キーアサイン — nape-hud", "読み出し中…");
        wait.Show();
        Task.Run(() =>
        {
            string text;
            try
            {
                using var via = new ViaClient(dev);
                text = KeymapReport.Text(via.ReadSnapshot(_cfg.Keymap), _cfg);
            }
            catch (AppError e) { text = "読み出せませんでした。\n\n" + e.Message; }
            catch (Exception e) { text = "読み出し中に問題が起きました。\n\n" + e.Message; }

            try { wait.BeginInvoke(() => { wait.Close(); new TextWindow("キーアサイン — nape-hud", text).Show(); }); }
            catch (InvalidOperationException) { /* すでに閉じられている */ }
        });
    }

    static void OpenConfig()
    {
        var path = File.Exists(_cfgPath) ? _cfgPath : Config.PreferredPath();
        if (!File.Exists(path))
        {
            // 内蔵の既定値を書き出してから開く。編集の出発点になる
            var json = Config.DefaultJson();
            if (json == null)
            {
                MessageBox.Show("設定ファイルがまだありません。", "nape-hud",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(path, json);
            }
            catch (Exception e)
            {
                MessageBox.Show("設定ファイルを作れませんでした。\n" + e.Message, "nape-hud",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
        }
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception e)
        {
            MessageBox.Show("開けませんでした。\n" + path + "\n" + e.Message, "nape-hud",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    static void ReloadConfig()
    {
        Config next;
        string nextPath;
        try { next = Config.Load(null, out nextPath); }
        catch (AppError e)
        {
            MessageBox.Show(e.Message, "nape-hud", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        if (next.Rules.Count == 0)
        {
            MessageBox.Show("読み込んだ設定に rules がありません。前の設定を使い続けます。",
                "nape-hud", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        _cfg = next;
        _cfgPath = nextPath;
        _decoder = new StateDecoder(_cfg.Rules);
        _tray.Visible = _cfg.Hud.ShowMenuBarIcon;

        // HUD は設定を抱えているので作り直す
        var old = _hud;
        _hud = new HudWindow(_cfg);
        _ = _hud.Handle;
        old.Dispose();

        _monitorKey = "";       // 次の見張りで貼り直させる
        _lastTrouble = "";
        EnsureMonitor();
        UpdateTrayIcon(null);
        _hud.Present(new HudContent("設定を読み込みました", nextPath, null));
    }
}
