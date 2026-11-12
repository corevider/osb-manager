using System.Drawing.Imaging;
using OsbManager.Core.Accounts;
using OsbManager.UI;

namespace OsbManager.Shots;

/// <summary>
/// Lays the main window out at the fixture's size and scale without showing it on screen, selects tabs and draws
/// the window into bitmaps. Only this process's own window is drawn.
/// </summary>
internal sealed class ShotCamera(MainForm form, ShotFixture fixture)
{
    private const int LeftPanelWidth = 230;
    private const uint NoZOrderNoActivate = 0x0004 | 0x0010;

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);

    public void Prepare()
    {
        form.TopLevel = false;
        form.FormBorderStyle = FormBorderStyle.None;
        form.Show();
        Resize(fixture.ClientSize.Width, fixture.ClientSize.Height);
        Settle();
        Descendants<SplitContainer>(form).Single().SplitterDistance = LeftPanelWidth;
        SelectAccount(fixture.Selected);
        Settle();
        ScaleUp();
        Settle();
    }

    private void ScaleUp()
    {
        var controls = Descendants<Control>(form).ToList();
        var sizes = controls.ToDictionary(c => c, c => c.Size);
        var font = new Font(form.Font.FontFamily, form.Font.Size * fixture.Scale, form.Font.Style);
        form.SuspendLayout();
        form.Font = font;
        foreach (var strip in Descendants<ToolStrip>(form))
        {
            strip.Font = font;
        }
        foreach (var control in controls)
        {
            control.Margin = Scaled(control.Margin);
            control.Padding = Scaled(control.Padding);
            control.MinimumSize = Scaled(control.MinimumSize);
            control.MaximumSize = Scaled(control.MaximumSize);
            if (control.Dock == DockStyle.None)
            {
                control.Size = Scaled(sizes[control]);
            }
            switch (control)
            {
                case ListView list:
                    foreach (ColumnHeader column in list.Columns)
                    {
                        column.Width = Scaled(column.Width);
                    }
                    break;
                case TreeView tree:
                    tree.Indent = Scaled(tree.Indent);
                    break;
                case SplitContainer split:
                    split.SplitterWidth = Scaled(split.SplitterWidth);
                    break;
                case TabControl tabs:
                    tabs.Padding = new Point(Scaled(tabs.Padding.X), Scaled(tabs.Padding.Y));
                    break;
            }
        }
        form.ResumeLayout(true);
        Resize(Scaled(fixture.ClientSize.Width), Scaled(fixture.ClientSize.Height));
        Descendants<SplitContainer>(form).Single().SplitterDistance = Scaled(LeftPanelWidth);
    }

    private void Resize(int width, int height) =>
        SetWindowPos(form.Handle, IntPtr.Zero, 0, 0, width, height, NoZOrderNoActivate);

    private Size Scaled(Size size) => new(Scaled(size.Width), Scaled(size.Height));

    private Padding Scaled(Padding padding) =>
        new(Scaled(padding.Left), Scaled(padding.Top), Scaled(padding.Right), Scaled(padding.Bottom));

    public IReadOnlyList<string> CaptureAll(string directory)
    {
        Directory.CreateDirectory(directory);
        var saved = new List<string>();
        foreach (var shot in fixture.Shots)
        {
            var size = shot.Size ?? fixture.ClientSize;
            Resize(Scaled(size.Width), Scaled(size.Height));
            SelectTab(shot.Left);
            SelectTab(shot.Tab);
            Descendants<SplitContainer>(form).Single().SplitterDistance = Scaled(shot.LeftWidth);
            Settle();
            ShowLog();
            var path = Path.Combine(directory, shot.File + ".png");
            using (var bitmap = new Bitmap(form.Width, form.Height, PixelFormat.Format32bppArgb))
            {
                form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
                using var cropped = shot.Crop is { } crop ? bitmap.Clone(new Rectangle(crop.X, crop.Y, crop.Width, crop.Height), bitmap.PixelFormat) : null;
                (cropped ?? bitmap).Save(path, ImageFormat.Png);
            }
            saved.Add(path);
        }
        return saved;
    }

    private int Scaled(int value) => (int)Math.Round(value * fixture.Scale);

    private void SelectAccount(string name)
    {
        var tree = Descendants<TreeView>(form).Single();
        var node = tree.Nodes.Cast<TreeNode>().SelectMany(root => root.Nodes.Cast<TreeNode>())
            .FirstOrDefault(n => n.Tag is Account account && account.Name == name)
            ?? throw new InvalidDataException($"The fixture selects {name}, which is not one of its accounts.");
        tree.SelectedNode = node;
    }

    private void SelectTab(string title)
    {
        var page = Descendants<TabControl>(form).SelectMany(tabs => tabs.TabPages.Cast<TabPage>()).FirstOrDefault(p => p.Text == title)
            ?? throw new InvalidDataException($"The main window has no tab named {title}.");
        ((TabControl)page.Parent!).SelectedTab = page;
    }

    private void ShowLog()
    {
        var log = Descendants<ListBox>(form).Single();
        log.BeginUpdate();
        log.Items.Clear();
        foreach (var line in fixture.Log)
        {
            log.Items.Add(line.ToString());
        }
        log.EndUpdate();
        log.TopIndex = Math.Max(0, log.Items.Count - 1);
        log.Update();
    }

    private static void Settle()
    {
        for (var i = 0; i < 25; i++)
        {
            Application.DoEvents();
            Thread.Sleep(40);
        }
    }

    private static IEnumerable<T> Descendants<T>(Control root) where T : Control
    {
        foreach (Control child in root.Controls)
        {
            if (child is T match)
            {
                yield return match;
            }
            foreach (var nested in Descendants<T>(child))
            {
                yield return nested;
            }
        }
    }
}
