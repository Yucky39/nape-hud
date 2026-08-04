using System.Drawing.Drawing2D;

namespace NapeHud;

/// <summary>ポップアップに出す内容。</summary>
public readonly record struct HudContent(string Big, string Sub, int? AngleDeg);

/// <summary>
/// 画面の隅に数秒だけ出る半透明のポップアップ。macOS 版の HUD に相当する。
///
/// 操作の邪魔をしないため、クリックを透過し（WS_EX_TRANSPARENT）、
/// フォーカスを奪わず（WS_EX_NOACTIVATE）、タスクバーにも Alt-Tab にも出さない
/// （WS_EX_TOOLWINDOW）。この 3 つが揃っていないと、入力中に前面へ出た瞬間に
/// キー入力を取られたり、Alt-Tab の一覧を汚したりする。
/// </summary>
public sealed class HudWindow : Form
{
    const int WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80,
              WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x8000000;

    readonly Config _cfg;
    readonly System.Windows.Forms.Timer _hide = new();
    HudContent _content = new("", "", null);
    Font _big = null!, _sub = null!;

    public HudWindow(Config cfg)
    {
        _cfg = cfg;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.FromArgb(22, 22, 24);
        Opacity = 0.92;
        DoubleBuffered = true;
        Text = "nape-hud";

        _hide.Tick += (_, _) => { _hide.Stop(); Hide(); };
        BuildFonts();
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_NOACTIVATE;
            return cp;
        }
    }

    /// <summary>
    /// 拡大率は「設定の scale × その画面の DPI」で決める。
    /// PerMonitorV2 で動かすので、画面ごとに倍率が違っても崩れない。
    /// </summary>
    double Zoom => Math.Max(0.5, _cfg.Hud.Scale) * (DeviceDpi / 96.0);

    void BuildFonts()
    {
        _big?.Dispose();
        _sub?.Dispose();
        _big = new Font("Segoe UI Semibold", (float)(23 * Zoom), GraphicsUnit.Pixel);
        _sub = new Font("Segoe UI", (float)(13 * Zoom), GraphicsUnit.Pixel);
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        BuildFonts();
        Relayout();
    }

    /// <summary>内容を差し替えて表示し、表示時間を数え直す。</summary>
    public void Present(HudContent c)
    {
        _content = c;
        BuildFonts();
        Relayout();
        Invalidate();

        if (!Visible) Show();
        // 他のウィンドウが前面に来た後でも確実に上へ出す
        TopMost = false;
        TopMost = true;

        _hide.Stop();
        _hide.Interval = Math.Max(200, (int)(_cfg.Hud.Seconds * 1000));
        _hide.Start();
    }

    void Relayout()
    {
        double z = Zoom;
        int padX = (int)(22 * z), padY = (int)(16 * z);
        int dial = _cfg.Hud.ShowAngleDial && _content.AngleDeg.HasValue ? (int)(58 * z) : 0;
        int gap = dial > 0 ? (int)(16 * z) : 0;

        var bigSize = TextRenderer.MeasureText(_content.Big, _big);
        var subSize = _content.Sub.Length > 0
            ? TextRenderer.MeasureText(_content.Sub, _sub) : Size.Empty;

        int textW = Math.Max(bigSize.Width, subSize.Width);
        int textH = bigSize.Height + (subSize.Height > 0 ? (int)(4 * z) + subSize.Height : 0);

        int w = padX * 2 + textW + gap + dial;
        int h = padY * 2 + Math.Max(textH, dial);
        w = Math.Max(w, (int)(180 * z));

        var screen = _cfg.Hud.FollowsMouseScreen
            ? Screen.FromPoint(Cursor.Position)
            : Screen.PrimaryScreen ?? Screen.FromPoint(Point.Empty);
        var wa = screen.WorkingArea;
        int m = (int)(_cfg.Hud.Margin * z);

        int x = _cfg.Hud.Position switch
        {
            "topLeft" or "bottomLeft" => wa.Left + m,
            "center" => wa.Left + (wa.Width - w) / 2,
            _ => wa.Right - w - m,          // topRight / bottomRight（既定）
        };
        int y = _cfg.Hud.Position switch
        {
            "bottomLeft" or "bottomRight" => wa.Bottom - h - m,
            "center" => wa.Top + (wa.Height - h) / 2,
            _ => wa.Top + m,                // topLeft / topRight（既定）
        };

        Bounds = new Rectangle(x, y, w, h);
        Region?.Dispose();
        using var path = RoundedRect(new Rectangle(0, 0, w, h), (int)(14 * z));
        Region = new Region(path);
    }

    static GraphicsPath RoundedRect(Rectangle r, int radius)
    {
        int d = Math.Max(2, radius * 2);
        var p = new GraphicsPath();
        p.AddArc(r.Left, r.Top, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Top, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

        double z = Zoom;
        int padX = (int)(22 * z), padY = (int)(16 * z);
        int dial = _cfg.Hud.ShowAngleDial && _content.AngleDeg.HasValue ? (int)(58 * z) : 0;

        // 縁を薄く光らせて背景から分離する
        using (var pen = new Pen(Color.FromArgb(60, 255, 255, 255), 1f))
        using (var path = RoundedRect(new Rectangle(0, 0, Width - 1, Height - 1), (int)(14 * z)))
            g.DrawPath(pen, path);

        var bigSize = TextRenderer.MeasureText(_content.Big, _big);
        var subSize = _content.Sub.Length > 0
            ? TextRenderer.MeasureText(_content.Sub, _sub) : Size.Empty;
        int textH = bigSize.Height + (subSize.Height > 0 ? (int)(4 * z) + subSize.Height : 0);
        int ty = (Height - textH) / 2;

        TextRenderer.DrawText(g, _content.Big, _big, new Point(padX, ty), Color.White);
        if (subSize.Height > 0)
            TextRenderer.DrawText(g, _content.Sub, _sub,
                new Point(padX, ty + bigSize.Height + (int)(4 * z)),
                Color.FromArgb(170, 255, 255, 255));

        if (dial > 0) DrawDial(g, new Rectangle(Width - padX - dial, (Height - dial) / 2, dial, dial),
                               _content.AngleDeg!.Value);
    }

    /// <summary>8 方向のダイヤル。0° を上にして時計回りに並べる。</summary>
    void DrawDial(Graphics g, Rectangle r, int deg)
    {
        float cx = r.Left + r.Width / 2f, cy = r.Top + r.Height / 2f;
        float radius = r.Width / 2f - r.Width * 0.12f;
        int active = ((deg % 360 + 360) % 360) / 45;

        using var ring = new Pen(Color.FromArgb(45, 255, 255, 255), Math.Max(1f, r.Width * 0.03f));
        g.DrawEllipse(ring, cx - radius, cy - radius, radius * 2, radius * 2);

        for (int i = 0; i < 8; i++)
        {
            // 画面座標は下が正なので、上を 0° にするため -90° ずらす
            double rad = (i * 45 - 90) * Math.PI / 180;
            float px = cx + (float)(Math.Cos(rad) * radius);
            float py = cy + (float)(Math.Sin(rad) * radius);
            bool on = i == active;
            float d = r.Width * (on ? 0.20f : 0.10f);
            using var b = new SolidBrush(on ? Color.White : Color.FromArgb(80, 255, 255, 255));
            g.FillEllipse(b, px - d / 2, py - d / 2, d, d);

            if (on)
            {
                using var line = new Pen(Color.White, Math.Max(1.5f, r.Width * 0.045f));
                g.DrawLine(line, cx, cy, px, py);
            }
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _hide.Dispose();
            _big?.Dispose();
            _sub?.Dispose();
        }
        base.Dispose(disposing);
    }
}
