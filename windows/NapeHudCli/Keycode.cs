namespace NapeHud;

/// <summary>QMK / VIA のキーコードを人が読める名前にする（macOS 版と同じ表記）。</summary>
public static class Keycode
{
    public static string ShortName(ushort code)
    {
        if (code == 0x0000) return "----";
        if (code == 0x0001) return "TRNS";

        if (code >= 0x0100 && code <= 0x1FFF)
        {
            int mods = (code >> 8) & 0x1F;
            var baseKey = (ushort)(code & 0xFF);
            bool right = (mods & 0x10) != 0;
            var parts = new List<string>();
            if ((mods & 0x01) != 0) parts.Add(right ? "R^" : "^");
            if ((mods & 0x02) != 0) parts.Add(right ? "R⇧" : "⇧");
            if ((mods & 0x04) != 0) parts.Add(right ? "R⌥" : "⌥");
            if ((mods & 0x08) != 0) parts.Add(right ? "R⌘" : "⌘");
            return string.Concat(parts) + Basic(baseKey);
        }
        // レイヤー関連。QMK の並びに当てると番号がレイヤー数と合わないため名前は出さない
        if (code >= 0x5000 && code <= 0x5FFF) return $"LYR:{code:X4}";
        if (code >= 0x7E00 && code <= 0x7FFF) return $"KC:{code:X4}";
        if (code <= 0x00FF) return Basic(code);
        return code.ToString("X4");
    }

    static string Basic(ushort c)
    {
        if (Short.TryGetValue(c, out var s)) return s;
        if (c >= 0x04 && c <= 0x1D) return ((char)('A' + (c - 0x04))).ToString();
        if (c >= 0x1E && c <= 0x26) return (c - 0x1D).ToString();
        if (c == 0x27) return "0";
        if (c >= 0x3A && c <= 0x45) return $"F{c - 0x39}";
        if (c >= 0x68 && c <= 0x73) return $"F{c - 0x5F}";
        return c.ToString("X2");
    }

    static readonly Dictionary<ushort, string> Short = new()
    {
        [0x28] = "Enter", [0x29] = "Esc", [0x2A] = "BSpc", [0x2B] = "Tab", [0x2C] = "Space",
        [0x2D] = "-", [0x2E] = "=", [0x2F] = "[", [0x30] = "]", [0x31] = "\\",
        [0x33] = ";", [0x34] = "'", [0x35] = "`", [0x36] = ",", [0x37] = ".", [0x38] = "/",
        [0x39] = "Caps", [0x49] = "Ins", [0x4A] = "Home", [0x4B] = "PgUp",
        [0x4C] = "Del", [0x4D] = "End", [0x4E] = "PgDn",
        [0x4F] = "→", [0x50] = "←", [0x51] = "↓", [0x52] = "↑",
        [0xA8] = "Mute", [0xA9] = "Vol+", [0xAA] = "Vol-",
        [0xAB] = "Next", [0xAC] = "Prev", [0xAD] = "Stop", [0xAE] = "Play",
        [0xCD] = "MsUp", [0xCE] = "MsDn", [0xCF] = "MsLt", [0xD0] = "MsRt",
        [0xD1] = "Btn1", [0xD2] = "Btn2", [0xD3] = "Btn3", [0xD4] = "Btn4", [0xD5] = "Btn5",
        [0xD9] = "WhUp", [0xDA] = "WhDn", [0xDB] = "WhLt", [0xDC] = "WhRt",
        [0xE0] = "LCtl", [0xE1] = "LSft", [0xE2] = "LAlt", [0xE3] = "LCmd",
        [0xE4] = "RCtl", [0xE5] = "RSft", [0xE6] = "RAlt", [0xE7] = "RCmd",
    };
}
