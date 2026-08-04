using System.Text;

namespace NapeHud;

/// <summary>読み出したキーマップを整形する（macOS 版と同じ内容）。</summary>
public static class KeymapReport
{
    public static string Text(KeymapSnapshot s, Config cfg)
    {
        var o = new List<string>();
        o.Add("Keychron Nape Pro キーアサイン（VIA プロトコルで読み出し）");
        o.Add($"プロトコル版数 {s.ProtocolVersion} / レイヤー {s.LayerCount}"
            + (s.ReportedLayerCount != s.LayerCount
               ? $"（デバイス申告 {s.ReportedLayerCount} / Launcher が見せるのは {s.LayerCount}）" : "")
            + $" / マトリクス {s.MatrixRows} 行 × {s.KeysPerLayer} 列"
            + $" / ダイヤル {s.EncoderCount} 個"
            + $" / マクロ {s.MacroCount} スロット{(s.MacrosEmpty ? "（未使用）" : "")}");
        o.Add(s.CoordinateVerified
            ? "キー数は座標指定の読み出し（0x04）と一致を確認済み"
            : "⚠️ キー数の自動判定を座標読みで検算できませんでした。keymap.keysPerLayer で固定してください");
        o.Add("");
        o.Add("⚠️ これは VIA のキーマップ領域の生の内容です。Launcher の表示とは一致しません。");
        o.Add("　 実機の割り当ては「レイヤー × 角度 × 単押し/長押し」で決まり、");
        o.Add("　 その全体はこの領域には入っていません（角度別の読み出しは未実装）。");
        o.Add("");

        int w = 12;
        var header = Fmt.Pad("レイヤー", 16);
        for (int c = 0; c < Math.Max(s.KeysPerLayer, 1); c++) header += Fmt.Pad($"col{c}", w);
        header += Fmt.Pad("ダイヤル↻", w) + Fmt.Pad("ダイヤル↺", w);
        o.Add(header);
        o.Add(new string('-', 16 + (s.KeysPerLayer + 2) * w));

        var vendor = new SortedSet<ushort>();
        for (int l = 0; l < s.LayerCount; l++)
        {
            var row = l < s.Keymap.Count ? s.Keymap[l] : Array.Empty<ushort>();
            var line = Fmt.Pad($"{l}: {cfg.LayerNameByNumber(l)}", 16);
            for (int k = 0; k < s.KeysPerLayer; k++)
            {
                ushort code = k < row.Length ? row[k] : (ushort)0;
                if (code >= 0x7E00) vendor.Add(code);
                line += Fmt.Pad(Keycode.ShortName(code), w);
            }
            var enc = l < s.Encoders.Count ? s.Encoders[l] : ((ushort)0, (ushort)0);
            line += Fmt.Pad(Keycode.ShortName(enc.Item1), w) + Fmt.Pad(Keycode.ShortName(enc.Item2), w);
            o.Add(line);
        }

        o.Add("");
        o.Add("凡例");
        o.Add("  ----      未割り当て / TRNS 下位レイヤーを透過");
        o.Add("  Btn1〜5   マウスボタン / WhUp・WhDn ホイール / Vol± 音量");
        o.Add("  LYR:xxxx  レイヤー関連のキーコード。正確な意味は未確認");
        if (vendor.Count > 0)
            o.Add("  KC:7Exx   Keychron 独自キーコード（名称非公開）。観測値: "
                  + string.Join(", ", vendor.Select(v => $"0x{v:X4}")));

        o.Add("");
        o.Add("── 実機の仕様 ──");
        o.Add("  レイヤー   全 8 段（状態通知は 1〜8、Launcher の表示は 0〜7）");
        o.Add("  OctaShift  0°〜315° の 8 方向");
        o.Add("  割り当て可 6 キー（M1 / M2 / 01 / 02 / 03 / 04）＋ ダイヤル上下");
        o.Add("  各キーは「単押し」と「長押し」で別の動作を割り当てられる");
        return string.Join(Environment.NewLine, o);
    }

}
