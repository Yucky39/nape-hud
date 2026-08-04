namespace NapeHud;

/// <summary>
/// 設定に一致するデバイスを開いてレポートを読み続ける。CLI 版と GUI 版で共有する。
///
/// インターフェース（面）ごとに 1 スレッドで読む。呼び出し側に渡すときは
/// 錠を取って直列化する — StateDecoder も呼び出し側の集計もスレッド安全ではない。
/// </summary>
public sealed class DeviceMonitor : IDisposable
{
    /// <summary>usagePage / usage / reportId / 本体（レポート ID を除いた部分）。</summary>
    public delegate void ReportHandler(WinHid.DeviceInfo dev, byte reportId, byte[] bytes);

    readonly List<HidStream> _streams = new();
    readonly List<Thread> _threads = new();
    readonly object _gate = new();
    bool _stopped;

    /// <summary>監視しているインターフェース。</summary>
    public List<WinHid.DeviceInfo> Targets { get; } = new();

    /// <summary>開けなかったインターフェースの説明（利用者への案内用）。</summary>
    public List<string> Failures { get; } = new();

    /// <summary>
    /// 監視を始める。1 つも開けなければ AppError を投げる。
    /// onReport は読み取りスレッドから直列化して呼ばれる。
    /// </summary>
    public DeviceMonitor(Config cfg, ReportHandler onReport, CancellationToken token)
    {
        var pages = cfg.Device.UsagePages;
        Targets.AddRange(WinHid.Enumerate()
            .Where(d => cfg.Device.Matches(d.VendorId, d.ProductId, d.Product))
            .Where(d => pages.Count == 0 || pages.Contains(d.UsagePage))
            .Where(d => d.InputReportLength > 0));

        if (Targets.Count == 0)
            throw new AppError("監視できるインターフェースがありません。\n"
                + "`nape-hud devices` で状況を確認してください。\n"
                + "Bluetooth 接続ではベンダ面が出ないため検出できません。");

        foreach (var t in Targets)
        {
            var stream = WinHid.Open(t);
            if (stream == null)
            {
                Failures.Add($"{t.Product} 0x{t.UsagePage:X4}（OS または他のソフトが占有している可能性）");
                continue;
            }
            _streams.Add(stream);

            var th = new Thread(() =>
            {
                var buf = new byte[stream.InputReportLength];
                while (!token.IsCancellationRequested && !_stopped)
                {
                    // 無限待ちにすると停止要求で抜けられないので、区切って待つ
                    int n = stream.Read(buf, 250);
                    if (n == 0) continue;      // タイムアウト
                    if (n < 0) break;          // 切断
                    if (n < 2) continue;
                    // Windows の HID 読み出しは先頭がレポート ID
                    var bytes = new byte[n - 1];
                    Array.Copy(buf, 1, bytes, 0, n - 1);
                    lock (_gate) onReport(t, buf[0], bytes);
                }
            }) { IsBackground = true, Name = $"hid-{t.UsagePage:X4}" };
            th.Start();
            _threads.Add(th);
        }

        if (_threads.Count == 0)
            throw new AppError("どのインターフェースも開けませんでした。\n"
                + string.Join("\n", Failures.Select(f => "  " + f)));
    }

    /// <summary>状態通知が来る面（0xFF60）を掴めているか。掴めていないと何も検出できない。</summary>
    public bool HasVendorInterface => Targets.Any(t => t.UsagePage == 0xFF60);

    public void Dispose()
    {
        _stopped = true;
        foreach (var s in _streams) s.Dispose();
        _streams.Clear();
    }
}
