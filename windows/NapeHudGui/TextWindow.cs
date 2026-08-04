namespace NapeHud;

/// <summary>キーアサインや診断結果を出す、読むだけの窓。</summary>
public sealed class TextWindow : Form
{
    readonly TextBox _box;

    public TextWindow(string title, string body)
    {
        Text = title;
        StartPosition = FormStartPosition.CenterScreen;
        // 等幅で桁を揃えて出す前提なので、初期サイズは広めに取る
        ClientSize = new Size(940, 560);
        MinimumSize = new Size(480, 260);
        BackColor = Color.FromArgb(30, 30, 32);

        _box = new TextBox
        {
            Multiline = true,
            ReadOnly = true,
            ScrollBars = ScrollBars.Both,
            WordWrap = false,
            Dock = DockStyle.Fill,
            BorderStyle = BorderStyle.None,
            BackColor = Color.FromArgb(30, 30, 32),
            ForeColor = Color.FromArgb(232, 232, 235),
            Font = new Font("Consolas", 12.5f, GraphicsUnit.Pixel),
            Text = body.Replace("\n", Environment.NewLine),
        };
        Controls.Add(_box);
        // 開いた直後に全選択状態だと読みにくい
        Shown += (_, _) => { _box.SelectionLength = 0; };
    }

    /// <summary>Esc で閉じる。</summary>
    protected override bool ProcessDialogKey(Keys keyData)
    {
        if (keyData == Keys.Escape) { Close(); return true; }
        return base.ProcessDialogKey(keyData);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _box.Font.Dispose();
        base.Dispose(disposing);
    }
}
