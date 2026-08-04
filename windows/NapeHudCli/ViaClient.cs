namespace NapeHud;

/// <summary>
/// raw HID (0xFF60) 上の VIA プロトコルでキーマップを読む。
/// 実測で確認したコマンド: 0x01 版数 / 0x11 レイヤー数 / 0x0C マクロ数 /
/// 0x12 キーマップ / 0x14 エンコーダ / 0x04 座標指定の読み出し。
/// 応答は先頭に要求バイト列がそのまま返るので、状態通知 0xA3 と区別できる。
/// </summary>
public sealed class ViaClient : IDisposable
{
    readonly HidStream _hid;

    public ViaClient(WinHid.DeviceInfo dev)
    {
        _hid = WinHid.Open(dev)
            ?? throw new AppError("raw HID インターフェースを開けませんでした。\n"
                + "Keychron Launcher が開いていると占有されることがあります。閉じてから試してください。");
        if (!_hid.CanWrite)
        {
            _hid.Dispose();
            throw new AppError("raw HID インターフェースを書き込み用に開けませんでした。\n"
                + "Keychron Launcher など他のソフトが使用中の可能性があります。");
        }
    }

    public void Dispose() => _hid.Dispose();

    /// <summary>要求を送って、先頭が一致する応答を待つ。</summary>
    byte[] Request(byte[] req, int timeoutMs = 500)
    {
        // 先頭 1 バイトはレポート ID。出力レポート長への詰め物は HidStream 側でやる。
        var packet = new byte[1 + req.Length];
        Array.Copy(req, 0, packet, 1, req.Length);
        if (!_hid.Write(packet))
            throw new AppError($"要求を送信できませんでした（{Program.Hex(req)}）。");

        var buf = new byte[_hid.InputReportLength];
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (true)
        {
            int remain = (int)(deadline - DateTime.UtcNow).TotalMilliseconds;
            if (remain <= 0) break;
            int n = _hid.Read(buf, remain);
            if (n < 0) break;          // 切断
            if (n <= 1) continue;      // タイムアウト / 中身なし
            var body = new byte[n - 1];
            Array.Copy(buf, 1, body, 0, n - 1);
            // 要求バイト列が先頭に返るのが VIA の約束。状態通知 0xA3 などは読み飛ばす。
            if (body.Length >= req.Length && body.Take(req.Length).SequenceEqual(req)) return body;
        }
        throw new AppError($"デバイスが応答しませんでした（{Program.Hex(req)}）。\n"
            + "Keychron Launcher が開いていると応答を取り合うため、閉じてから試してください。");
    }

    public KeymapSnapshot ReadSnapshot(KeymapConfig settings)
    {
        var ver = Request(new byte[] { 0x01 });
        int protocolVersion = (ver[1] << 8) | ver[2];

        var layers = Request(new byte[] { 0x11 });
        int reported = Math.Max((int)layers[1], 1);
        int layerCount = settings.LayerCount > 0 ? Math.Min(settings.LayerCount, reported) : reported;

        var macros = Request(new byte[] { 0x0C });
        int macroCount = macros[1];

        // キーマップ本体。1 往復で 28 バイトまで（32 − ヘッダ 4）
        const int chunk = 28;
        var raw = new List<byte>();
        for (int offset = 0; offset < 1024; offset += chunk)
        {
            var resp = Request(new byte[] { 0x12, (byte)(offset >> 8), (byte)(offset & 0xFF), chunk });
            if (resp.Length < 4 + chunk) break;
            raw.AddRange(resp.Skip(4).Take(chunk));
            if (raw.Count >= chunk * 2 && raw.Skip(raw.Count - chunk * 2).All(b => b == 0)) break;
        }

        var codes = new List<ushort>();
        for (int i = 0; i + 1 < raw.Count; i += 2)
            codes.Add((ushort)((raw[i] << 8) | raw[i + 1]));

        int keysPerLayer;
        if (settings.KeysPerLayer > 0) keysPerLayer = settings.KeysPerLayer;
        else
        {
            int last = codes.FindLastIndex(c => c != 0);
            keysPerLayer = last < 0 ? 0 : Math.Max(1, (int)Math.Ceiling((last + 1) / (double)reported));
        }

        var keymap = new List<ushort[]>();
        for (int l = 0; l < layerCount && keysPerLayer > 0; l++)
        {
            int start = l * keysPerLayer;
            int end = Math.Min(start + keysPerLayer, codes.Count);
            keymap.Add(start < end ? codes.GetRange(start, end - start).ToArray() : Array.Empty<ushort>());
        }

        var encoders = new List<(ushort Cw, ushort Ccw)>();
        for (int l = 0; l < layerCount; l++)
        {
            ushort cw = Val(TryRequest(new byte[] { 0x14, (byte)l, 0x00, 0x01 }));
            ushort ccw = Val(TryRequest(new byte[] { 0x14, (byte)l, 0x00, 0x00 }));
            encoders.Add((cw, ccw));
        }

        int encoderCount = 0;
        for (int e = 0; e < 8; e++)
        {
            ushort cw = Val(TryRequest(new byte[] { 0x14, 0x00, (byte)e, 0x01 }));
            ushort ccw = Val(TryRequest(new byte[] { 0x14, 0x00, (byte)e, 0x00 }));
            if (cw == 0 && ccw == 0) break;
            encoderCount = e + 1;
        }

        // 0x04（座標指定）で一括読みの解釈を検算する
        bool verified = false;
        if (keysPerLayer > 0 && keymap.Count > 0 && keymap[0].Length == keysPerLayer)
        {
            var byCoord = new List<ushort>();
            for (int c = 0; c < keysPerLayer; c++)
                byCoord.Add(Val(TryRequest(new byte[] { 0x04, 0x00, 0x00, (byte)c })));
            verified = byCoord.SequenceEqual(keymap[0]);
        }

        int rows = 1;
        for (int row = 1; row < 8; row++)
        {
            bool any = false;
            for (int c = 0; c < keysPerLayer; c++)
                if (Val(TryRequest(new byte[] { 0x04, 0x00, (byte)row, (byte)c })) != 0) { any = true; break; }
            if (!any) break;
            rows = row + 1;
        }

        var macroHead = TryRequest(new byte[] { 0x0E, 0x00, 0x00, 0x1C });
        bool macrosEmpty = macroHead != null && macroHead.Length >= 32
                           && macroHead.Skip(4).Take(28).All(b => b == 0);

        return new KeymapSnapshot(protocolVersion, layerCount, reported, macroCount,
                                  keysPerLayer, keymap, encoders, encoderCount, rows,
                                  verified, macrosEmpty);
    }

    byte[]? TryRequest(byte[] req) { try { return Request(req, 300); } catch { return null; } }
    static ushort Val(byte[]? resp) =>
        resp != null && resp.Length >= 6 ? (ushort)((resp[4] << 8) | resp[5]) : (ushort)0;
}

public sealed record KeymapSnapshot(
    int ProtocolVersion, int LayerCount, int ReportedLayerCount, int MacroCount,
    int KeysPerLayer, List<ushort[]> Keymap, List<(ushort Cw, ushort Ccw)> Encoders,
    int EncoderCount, int MatrixRows, bool CoordinateVerified, bool MacrosEmpty);
