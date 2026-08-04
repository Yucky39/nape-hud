namespace NapeHud;

/// <summary>デバイスが返す生値と、対応表を通した表示値の対。</summary>
public readonly record struct CodedValue(int Code, int? Value)
{
    public bool IsKnown => Value.HasValue;
}

public readonly record struct DeviceState(int? Layer, CodedValue? Angle, CodedValue? Dpi);

public enum ChangeKind { LayerPrimary, AnglePrimary, DpiPrimary, RepeatLast }

public readonly record struct StateChange(ChangeKind Kind, int Layer = 0, CodedValue Value = default);

/// <summary>
/// 生レポート → 状態変化。macOS 版の StateDecoder と同じ判定順を使う。
///
/// 実測で分かった非対称性:
///   レイヤー切替ボタン … レイヤー(offset 1)が動く。加えて「そのレイヤーに記憶された向き」も
///                        載るため向きフィールドまで変化することがある。
///   8 方向切替ボタン   … 向き(offset 2)だけが動く。
///   DPI 切替ボタン     … DPI(offset 3)だけが動く。
/// したがって「レイヤー → 向き → DPI」の順で見る。逆順にするとレイヤー表示が奪われる。
/// </summary>
public sealed class StateDecoder
{
    readonly List<Rule> _rules;
    public DeviceState State { get; private set; }
    public bool AnnounceInitial { get; set; } = true;
    public Action<string, int, byte[]>? OnUnmapped { get; set; }
    public Action<Rule, byte[], DeviceState>? OnMatched { get; set; }

    bool _sawAnything;
    readonly HashSet<string> _warned = new();

    public StateDecoder(List<Rule> rules) => _rules = rules;

    public StateChange? Ingest(int usagePage, int usage, int reportId, byte[] bytes)
    {
        foreach (var rule in _rules)
        {
            if (!rule.Applies(usagePage, usage, reportId, bytes)) continue;

            var newLayer = rule.Layer?.Extract(bytes);
            var newAngle = Coded(rule.Angle, bytes);
            var newDpi = Coded(rule.Dpi, bytes);

            WarnIfUnmapped("向き", newAngle, bytes);
            WarnIfUnmapped("DPI", newDpi, bytes);

            if (newLayer == null && newAngle == null && newDpi == null) continue;
            var change = Apply(newLayer, newAngle, newDpi, rule.NotifiesAlways);
            OnMatched?.Invoke(rule, bytes, State);
            return change;
        }
        return null;
    }

    static CodedValue? Coded(FieldSpec? spec, byte[] bytes)
    {
        if (spec == null) return null;
        var raw = spec.RawValue(bytes);
        if (raw == null) return null;
        return new CodedValue(raw.Value, spec.Converted(raw.Value));
    }

    void WarnIfUnmapped(string field, CodedValue? v, byte[] bytes)
    {
        if (v == null || v.Value.IsKnown) return;
        if (!_warned.Add($"{field}/{v.Value.Code}")) return;
        OnUnmapped?.Invoke(field, v.Value.Code, bytes);
    }

    StateChange? Apply(int? layer, CodedValue? angle, CodedValue? dpi, bool always)
    {
        var old = State;
        State = new DeviceState(layer ?? old.Layer, angle ?? old.Angle, dpi ?? old.Dpi);

        bool first = !_sawAnything && AnnounceInitial;
        _sawAnything = true;

        if (State.Layer != old.Layer && State.Layer.HasValue)
            return new StateChange(ChangeKind.LayerPrimary, State.Layer.Value);
        if (State.Angle != old.Angle && State.Angle.HasValue)
            return new StateChange(ChangeKind.AnglePrimary, Value: State.Angle.Value);
        if (State.Dpi != old.Dpi && State.Dpi.HasValue)
            return new StateChange(ChangeKind.DpiPrimary, Value: State.Dpi.Value);

        if (first)
        {
            if (State.Layer.HasValue) return new StateChange(ChangeKind.LayerPrimary, State.Layer.Value);
            if (State.Angle.HasValue) return new StateChange(ChangeKind.AnglePrimary, Value: State.Angle.Value);
            if (State.Dpi.HasValue) return new StateChange(ChangeKind.DpiPrimary, Value: State.Dpi.Value);
        }
        return always ? new StateChange(ChangeKind.RepeatLast) : null;
    }

    public void Reset()
    {
        State = default;
        _sawAnything = false;
        _warned.Clear();
    }
}
