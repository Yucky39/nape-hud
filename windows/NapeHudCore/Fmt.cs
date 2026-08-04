namespace NapeHud;

/// <summary>表示用の小さなヘルパ。</summary>
public static class Fmt
{
    /// <summary>レポートを 16 進で並べる。長いものは頭だけ出して残りは件数で示す。</summary>
    public static string Hex(byte[] b, int limit = 8) =>
        string.Join(" ", b.Take(limit).Select(x => x.ToString("X2")))
        + (b.Length > limit ? $" …({b.Length}B)" : "");

    /// <summary>全角を 2 桁として数え、等幅で桁を揃える。</summary>
    public static string Pad(string s, int width)
    {
        int w = s.Sum(c => IsWide(c) ? 2 : 1);
        return s + new string(' ', Math.Max(1, width - w));
    }

    static bool IsWide(char c)
    {
        int v = c;
        return (v >= 0x1100 && v <= 0x115F) || (v >= 0x2E80 && v <= 0xA4CF)
            || (v >= 0xAC00 && v <= 0xD7A3) || (v >= 0xF900 && v <= 0xFAFF)
            || (v >= 0xFE30 && v <= 0xFE6F) || (v >= 0xFF00 && v <= 0xFF60)
            || (v >= 0xFFE0 && v <= 0xFFE6) || v == 0x21BB || v == 0x21BA;
    }
}
