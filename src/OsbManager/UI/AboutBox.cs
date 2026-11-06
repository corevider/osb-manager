using System.Drawing.Drawing2D;
using OsbManager.Core;

namespace OsbManager.UI;

internal static class AboutBox
{
    private const int SealSize = 96;

    /// <summary>The details shown next to the seal, one per line.</summary>
    public static IReadOnlyList<string> Details(string version, string? runtimeVersion, string dataFolder) =>
    [
        $"Version {version}",
        "Corevider",
        $"WebView2 Runtime {runtimeVersion ?? "not installed"}",
        $"Data folder: {dataFolder}",
    ];

    public static void Show(IWin32Window owner, string version, string? runtimeVersion, string dataFolder)
    {
        using var form = new Form
        {
            Text = $"About {AppIdentity.Name}",
            FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterParent,
            MinimizeBox = false,
            MaximizeBox = false,
            ShowInTaskbar = false,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            AutoScaleMode = AutoScaleMode.Dpi,
            AutoScaleDimensions = new SizeF(96F, 96F),
            Padding = new Padding(16),
            Icon = AppIcon.Instance,
        };
        using var seal = SealImage(form.LogicalToDeviceUnits(SealSize));
        var layout = new TableLayoutPanel { ColumnCount = 2, RowCount = 2, AutoSize = true, Dock = DockStyle.Fill };
        var picture = new PictureBox
        {
            Image = seal,
            SizeMode = PictureBoxSizeMode.Zoom,
            Size = new Size(SealSize, SealSize),
            Margin = new Padding(0, 0, 16, 0),
            AccessibleName = $"{AppIdentity.Name} seal",
        };
        var text = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Margin = Padding.Empty };
        using var titleFont = new Font(form.Font.FontFamily, 14F, FontStyle.Bold);
        var title = new Label { Text = AppIdentity.Name, AutoSize = true, Font = titleFont, Margin = new Padding(0, 4, 0, 6) };
        text.Controls.Add(title);
        foreach (var line in Details(version, runtimeVersion, dataFolder))
        {
            text.Controls.Add(new Label { Text = line, AutoSize = true, MaximumSize = new Size(440, 0), Margin = new Padding(0, 0, 0, 3) });
        }
        var ok = new Button { Text = "OK", AutoSize = true, DialogResult = DialogResult.OK, Anchor = AnchorStyles.Right, Margin = new Padding(0, 12, 0, 0) };
        layout.Controls.Add(picture, 0, 0);
        layout.Controls.Add(text, 1, 0);
        layout.Controls.Add(ok, 1, 1);
        form.Controls.Add(layout);
        form.AcceptButton = ok;
        form.CancelButton = ok;
        form.ShowDialog(owner);
    }

    private static Bitmap SealImage(int size)
    {
        using var stream = typeof(AboutBox).Assembly.GetManifestResourceStream("OsbManager.app.ico")
            ?? throw new InvalidOperationException("The app icon is missing from the build.");
        using var icon = new Icon(stream, 256, 256);
        using var source = icon.ToBitmap();
        var target = new Bitmap(size, size);
        using var graphics = Graphics.FromImage(target);
        graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
        graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
        graphics.DrawImage(source, new Rectangle(0, 0, size, size));
        return target;
    }
}
