using System.Text.Json;
using System.Text.Json.Serialization;

namespace NapeHud;

// macOS 版と同じ config.json を読む。
// 未知のキー（hud / acceleration など GUI 専用の設定）は無視する。
// "//..." で始まるコメント用のキーも自然に無視される。

public sealed class Config
{
    public DeviceMatch Device { get; set; } = new();
    public Dictionary<string, string> LayerNames { get; set; } = new();
    public Dictionary<string, string> AngleNames { get; set; } = new();
    public Dictionary<string, string> DpiNames { get; set; } = new();
    public List<Rule> Rules { get; set; } = new();
    public CalibrationConfig Calibration { get; set; } = new();
    public KeymapConfig Keymap { get; set; } = new();
    /// <summary>表示に関する設定。CLI 版が使うのは layerNumberOffset だけ。</summary>
    public HudConfig Hud { get; set; } = new();

    /// <summary>レイヤー番号の表示補正。よく使うので短縮形を用意しておく。</summary>
    [JsonIgnore] public int LayerNumberOffset => Hud.LayerNumberOffset;

    static readonly JsonSerializerOptions Opts = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    /// <summary>
    /// 設定を読む。探索順は「指定パス → %APPDATA%\nape-hud → 実行ファイルの隣」。
    /// 見つからなければ既定値で動く（macOS 版と同じ挙動）。
    /// </summary>
    public static Config Load(string? explicitPath, out string usedPath)
    {
        foreach (var p in CandidatePaths(explicitPath))
        {
            if (!File.Exists(p)) continue;
            usedPath = p;
            var json = File.ReadAllText(p);
            return JsonSerializer.Deserialize<Config>(json, Opts) ?? new Config();
        }
        if (explicitPath != null)
        {
            usedPath = explicitPath;
            throw new AppError($"設定ファイルが読めません: {explicitPath}");
        }
        // どこにも無ければ実行ファイルに埋め込んだ既定値を使う
        var builtin = Builtin();
        if (builtin != null)
        {
            usedPath = "(内蔵の既定値)";
            return builtin;
        }
        usedPath = "(未検出・空の既定値で動作)";
        return new Config();
    }

    /// <summary>埋め込んだ既定の設定ファイルの中身。無ければ null。</summary>
    public static string? DefaultJson()
    {
        try
        {
            using var st = typeof(Config).Assembly.GetManifestResourceStream("config.default.json");
            if (st == null) return null;
            using var r = new StreamReader(st);
            return r.ReadToEnd();
        }
        catch { return null; }
    }

    /// <summary>設定が無いときに使う場所（%APPDATA%\nape-hud\config.json）。</summary>
    public static string PreferredPath()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return Path.Combine(appData.Length > 0 ? appData : AppContext.BaseDirectory,
                            "nape-hud", "config.json");
    }

    /// <summary>埋め込んだ config.example.json を読む。</summary>
    static Config? Builtin()
    {
        try
        {
            var json = DefaultJson();
            if (json == null) return null;
            var c = JsonSerializer.Deserialize<Config>(json, Opts);
            return c != null && c.Rules.Count > 0 ? c : null;
        }
        catch { return null; }
    }

    /// <summary>探索した場所を人に見せる用（見つからなかったときの案内）。</summary>
    public static string SearchOrder() => string.Join("\n", CandidatePaths(null).Select(p => "  " + p));

    static IEnumerable<string> CandidatePaths(string? explicitPath)
    {
        if (!string.IsNullOrEmpty(explicitPath)) { yield return explicitPath; yield break; }
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (!string.IsNullOrEmpty(appData))
            yield return Path.Combine(appData, "nape-hud", "config.json");
        var exeDir = AppContext.BaseDirectory;
        yield return Path.Combine(exeDir, "config.json");
    }

    public string LayerName(int rawLayer) => LayerNameByNumber(rawLayer + LayerNumberOffset);

    public string LayerNameByNumber(int n) =>
        LayerNames.TryGetValue(n.ToString(), out var s) && s.Length > 0 ? s : $"Layer {n}";

    public string AngleName(int deg) =>
        AngleNames.TryGetValue(deg.ToString(), out var s) && s.Length > 0 ? s : $"{deg}°";

    public string DpiName(int v)
    {
        if (DpiNames.TryGetValue(v.ToString(), out var s) && s.Length > 0)
            return int.TryParse(s, out _) ? $"{s} DPI" : s;
        return $"{v} DPI";
    }
}

public sealed class DeviceMatch
{
    public int VendorId { get; set; } = 0x3434;
    public List<int> ProductIds { get; set; } = new() { 0x0440, 0xD026 };
    public List<string> ProductNameContains { get; set; } = new() { "Nape", "Link-KM" };
    public Dictionary<string, string> ConnectionNames { get; set; } = new();
    /// <summary>監視するインターフェース。既定はベンダ面のみ（0xFF60 / 0x008C）。</summary>
    public List<int> UsagePages { get; set; } = new() { 0xFF60, 0x008C };

    public bool Matches(int vid, int pid, string product)
    {
        if (vid != VendorId) return false;
        if (ProductIds.Contains(pid)) return true;
        return ProductNameContains.Any(s =>
            s.Length > 0 && product.Contains(s, StringComparison.OrdinalIgnoreCase));
    }

    public string? ConnectionOverride(int pid) =>
        ConnectionNames.TryGetValue($"0x{pid:X4}", out var a) ? a
        : ConnectionNames.TryGetValue($"0x{pid:x4}", out var b) ? b
        : ConnectionNames.TryGetValue(pid.ToString(), out var c) ? c : null;
}

public sealed class Rule
{
    public string Name { get; set; } = "";
    public int? UsagePage { get; set; }
    public int? Usage { get; set; }
    public int? ReportId { get; set; }
    public int? MinLength { get; set; }
    public List<ByteMatch>? Match { get; set; }
    public FieldSpec? Layer { get; set; }
    public FieldSpec? Angle { get; set; }
    public FieldSpec? Dpi { get; set; }
    public string Notify { get; set; } = "always";

    public bool NotifiesAlways => !Notify.Equals("onChange", StringComparison.OrdinalIgnoreCase);

    public bool Applies(int usagePage, int usage, int reportId, byte[] bytes)
    {
        if (UsagePage.HasValue && UsagePage.Value != usagePage) return false;
        if (Usage.HasValue && Usage.Value != usage) return false;
        if (ReportId.HasValue && ReportId.Value != reportId) return false;
        if (MinLength.HasValue && bytes.Length < MinLength.Value) return false;
        if (Match != null)
            foreach (var m in Match) if (!m.Matches(bytes)) return false;
        return true;
    }
}

public sealed class ByteMatch
{
    public int Offset { get; set; }
    public List<int>? Equals_ { get; set; }
    [JsonPropertyName("equals")] public List<int>? EqualsList { get => Equals_; set => Equals_ = value; }
    public int? Mask { get; set; }

    public bool Matches(byte[] b)
    {
        if (Offset < 0 || Offset >= b.Length) return false;
        int v = b[Offset];
        if (Mask.HasValue) v &= Mask.Value;
        if (Equals_ == null || Equals_.Count == 0) return true;
        return Equals_.Contains(v);
    }
}

/// <summary>生バイト列から数値を 1 つ取り出す指定。macOS 版の FieldSpec と同じ。</summary>
public sealed class FieldSpec
{
    public int Offset { get; set; }
    public int Size { get; set; } = 1;
    public string Encoding { get; set; } = "value";
    public bool BigEndian { get; set; }
    public int Add { get; set; }
    public double Multiply { get; set; } = 1;
    public Dictionary<string, int>? Map { get; set; }

    public bool HasMap => Map != null;

    public int? RawValue(byte[] b)
    {
        if (Offset < 0 || Size <= 0 || Offset + Size > b.Length) return null;
        var slice = b.Skip(Offset).Take(Size).ToArray();

        if (Encoding is "bitmaskHighest" or "bitmaskLowest")
        {
            var bits = new List<int>();
            for (int i = 0; i < slice.Length; i++)
                for (int bit = 0; bit < 8; bit++)
                    if ((slice[i] & (1 << bit)) != 0) bits.Add(i * 8 + bit);
            if (bits.Count == 0) return null;
            return Encoding == "bitmaskHighest" ? bits.Max() : bits.Min();
        }

        var ordered = BigEndian ? slice : slice.Reverse().ToArray();
        int raw = 0;
        foreach (var x in ordered) raw = (raw << 8) | x;
        return raw;
    }

    /// <summary>map があれば引き当て（外れたら null = 未設定）、無ければ add/multiply 補正。</summary>
    public int? Converted(int raw)
    {
        if (Map != null)
            return Map.TryGetValue(raw.ToString(), out var v) ? v : null;
        return (int)Math.Round((raw + Add) * Multiply);
    }

    public int? Extract(byte[] b)
    {
        var raw = RawValue(b);
        return raw.HasValue ? Converted(raw.Value) : null;
    }
}

public sealed class CalibrationConfig
{
    public int Positions { get; set; } = 8;
    public int? AngleZeroCode { get; set; }
    public bool Clockwise { get; set; } = true;
}

/// <summary>
/// 表示の設定。macOS 版の HUDConfig と同じキーを読む。
/// CLI 版は layerNumberOffset だけ、GUI 版は全部使う。
/// </summary>
public sealed class HudConfig
{
    /// <summary>ポップアップを出しておく秒数。</summary>
    public double Seconds { get; set; } = 2.2;
    /// <summary>topLeft / topRight / bottomLeft / bottomRight / center。</summary>
    public string Position { get; set; } = "topRight";
    public double Margin { get; set; } = 28;
    public double Scale { get; set; } = 1.0;
    public bool ShowConnection { get; set; } = true;
    public bool ShowOnConnectionChange { get; set; } = true;
    /// <summary>OctaShift の向きを 8 方向のダイヤル図で描く。</summary>
    public bool ShowAngleDial { get; set; } = true;
    /// <summary>マウスがある画面に出す。false なら主ディスプレイ。</summary>
    public bool FollowsMouseScreen { get; set; } = true;
    /// <summary>通知領域に常駐する。false にすると終了操作ができなくなる。</summary>
    public bool ShowMenuBarIcon { get; set; } = true;
    /// <summary>常駐アイコンに現在のレイヤー番号を出す。</summary>
    public bool MenuBarShowsLayer { get; set; } = true;
    public int LayerNumberOffset { get; set; }
}

public sealed class KeymapConfig
{
    public int KeysPerLayer { get; set; }
    public int LayerCount { get; set; } = 8;
}

public sealed class AppError : Exception
{
    public AppError(string msg) : base(msg) { }
}
