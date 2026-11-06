using System.Globalization;
using OsbManager.Core;
using OsbManager.Core.Telemetry;

namespace OsbManager.UI;

internal sealed class UnsentReportsForm : Form
{
    private readonly ReportOutbox outbox;
    private readonly PrivacyTexts texts;
    private readonly ListView list = new() { View = View.Details, FullRowSelect = true, Width = 640, Height = 220, MultiSelect = false };
    private readonly Button sendAgain = new() { AutoSize = true, Enabled = false };
    private readonly Button delete = new() { AutoSize = true, Enabled = false };
    private readonly System.Windows.Forms.Timer refreshTimer = new() { Interval = 2000 };

    public UnsentReportsForm(ReportOutbox outbox, PrivacyTexts texts)
    {
        this.outbox = outbox;
        this.texts = texts;
        Text = $"{AppIdentity.Name} · {texts.UnsentTitle}";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = false;
        MaximizeBox = false;
        ShowInTaskbar = false;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(16);
        Icon = AppIcon.Instance;
        list.Columns.Add(texts.UnsentTitle, 220);
        list.Columns.Add("", 150);
        list.Columns.Add("#", 40);
        list.Columns.Add("", 200);
        sendAgain.Text = texts.SendAgain;
        delete.Text = texts.Delete;
        var close = new Button { Text = texts.Close, AutoSize = true, DialogResult = DialogResult.OK };
        var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Margin = new Padding(0, 8, 0, 0) };
        buttons.Controls.AddRange([sendAgain, delete, close]);
        var layout = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Dock = DockStyle.Fill };
        layout.Controls.AddRange([list, buttons]);
        Controls.Add(layout);
        AcceptButton = close;
        CancelButton = close;
        list.SelectedIndexChanged += (_, _) => UpdateButtons();
        sendAgain.Click += (_, _) =>
        {
            if (list.SelectedItems.Count == 1 && list.SelectedItems[0].Tag is (string id, true))
            {
                outbox.SendAgain(id);
                Reload();
            }
        };
        delete.Click += (_, _) =>
        {
            if (list.SelectedItems.Count == 1 && list.SelectedItems[0].Tag is (string id, bool failed))
            {
                if (failed)
                {
                    outbox.DeleteFailed(id);
                }
                else
                {
                    outbox.Remove(id);
                }
                Reload();
            }
        };
        refreshTimer.Tick += (_, _) => Reload();
        refreshTimer.Start();
        Reload();
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        refreshTimer.Stop();
        refreshTimer.Dispose();
        base.OnFormClosed(e);
    }

    private void Reload()
    {
        var selected = (list.SelectedItems.Count == 1 ? list.SelectedItems[0].Tag as (string, bool)? : null)?.Item1;
        list.BeginUpdate();
        list.Items.Clear();
        foreach (var entry in outbox.Pending())
        {
            Add(entry, failed: false, texts.UnsentPending, selected);
        }
        foreach (var entry in outbox.Failed())
        {
            Add(entry, failed: true, texts.UnsentFailed, selected);
        }
        list.EndUpdate();
        UpdateButtons();
    }

    private void Add(OutboxEntry entry, bool failed, string group, string? selected)
    {
        var item = new ListViewItem([group, entry.CreatedAt.ToLocalTime().ToString("g", CultureInfo.CurrentCulture), entry.Attempts.ToString(CultureInfo.CurrentCulture), entry.LastNote ?? ""])
        {
            Tag = (entry.Id, failed),
            Selected = entry.Id == selected,
        };
        list.Items.Add(item);
    }

    private void UpdateButtons()
    {
        var item = list.SelectedItems.Count == 1 ? list.SelectedItems[0] : null;
        delete.Enabled = item is not null;
        sendAgain.Enabled = item?.Tag is (string, true);
    }
}
