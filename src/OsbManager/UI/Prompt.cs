namespace OsbManager.UI;

internal static class Prompt
{
    /// <summary>Asks for one line of text; validate returns an error message or null.</summary>
    public static string? Ask(IWin32Window owner, string title, string label, string value, Func<string, string?> validate)
    {
        using var form = new Form
        {
            Text = title,
            FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterParent,
            MinimizeBox = false,
            MaximizeBox = false,
            ShowInTaskbar = false,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Padding = new Padding(12),
        };
        var layout = new TableLayoutPanel { ColumnCount = 1, AutoSize = true, Dock = DockStyle.Fill };
        var input = new TextBox { Text = value, Width = 520 };
        var error = new Label { AutoSize = true, ForeColor = Color.Firebrick };
        var ok = new Button { Text = "OK", AutoSize = true };
        var cancel = new Button { Text = "Cancel", AutoSize = true, DialogResult = DialogResult.Cancel };
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill };
        buttons.Controls.AddRange([cancel, ok]);
        layout.Controls.AddRange([new Label { Text = label, AutoSize = true }, input, error, buttons]);
        form.Controls.Add(layout);
        form.AcceptButton = ok;
        form.CancelButton = cancel;
        ok.Click += (_, _) =>
        {
            var problem = validate(input.Text);
            if (problem is null)
            {
                form.DialogResult = DialogResult.OK;
            }
            else
            {
                error.Text = problem;
            }
        };
        return form.ShowDialog(owner) == DialogResult.OK ? input.Text.Trim() : null;
    }
}
