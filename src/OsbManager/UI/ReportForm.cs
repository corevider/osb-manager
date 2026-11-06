using System.Globalization;
using System.Text.Json.Nodes;
using OsbManager.Core;
using OsbManager.Core.Telemetry;

namespace OsbManager.UI;

internal sealed record ReportWindowChoice(string Label, Func<Task<byte[]?>> Capture);

internal sealed class ReportForm : Form
{
    private const int ContentWidth = 620;

    private readonly TelemetryService telemetry;
    private readonly PrivacyTexts texts;
    private readonly string appVersion;
    private readonly string locale;
    private readonly JsonObject diagnostics;
    private readonly IReadOnlyList<ReportWindowChoice> windows;
    private readonly ComboBox kindBox = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 200 };
    private readonly TextBox descriptionBox = new() { Multiline = true, MaxLength = ReportPayload.MaxDescription, Width = ContentWidth, Height = 90, ScrollBars = ScrollBars.Vertical, AcceptsReturn = true };
    private readonly Label counterLabel = new() { AutoSize = true, ForeColor = SystemColors.GrayText };
    private readonly Button addShotButton = new() { AutoSize = true };
    private readonly Button removeShotButton = new() { AutoSize = true, Visible = false };
    private readonly PictureBox thumbnail = new() { Width = 160, Height = 90, SizeMode = PictureBoxSizeMode.Zoom, BorderStyle = BorderStyle.FixedSingle, Visible = false };
    private readonly LinkLabel policyLink = new() { AutoSize = true, Margin = new Padding(0, 4, 0, 0) };
    private readonly Label shotInfo = new() { AutoSize = true, UseMnemonic = false, MaximumSize = new Size(ContentWidth - 180, 0), Visible = false };
    private readonly Label noteLabel = new() { AutoSize = true, UseMnemonic = false, MaximumSize = new Size(ContentWidth, 0), Font = new Font(SystemFonts.DefaultFont, FontStyle.Bold) };
    private readonly TextBox previewBox = new()
    {
        Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, Width = ContentWidth, Height = 170,
        Font = new Font(FontFamily.GenericMonospace, 8.5F),
    };
    private readonly Label statusLabel = new() { AutoSize = true, UseMnemonic = false, MaximumSize = new Size(ContentWidth, 0), Margin = new Padding(0, 6, 0, 0) };
    private readonly Button sendButton = new() { AutoSize = true };
    private readonly Button cancelButton = new() { AutoSize = true, DialogResult = DialogResult.Cancel };
    private byte[]? screenshot;
    private byte[] reportJson = [];
    private bool finished;
    private CancellationTokenSource? sending;

    public ReportForm(TelemetryService telemetry, PrivacyTexts texts, string appVersion, string locale, JsonObject diagnostics, IReadOnlyList<ReportWindowChoice> windows)
    {
        this.telemetry = telemetry;
        this.texts = texts;
        this.appVersion = appVersion;
        this.locale = locale;
        this.diagnostics = diagnostics;
        this.windows = windows;
        Text = $"{AppIdentity.Name} · {texts.ReportTitle}";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = false;
        MaximizeBox = false;
        ShowInTaskbar = false;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96F, 96F);
        Padding = new Padding(16);
        Icon = AppIcon.Instance;

        kindBox.Items.AddRange([texts.KindBug, texts.KindFeature]);
        kindBox.SelectedIndex = 0;
        addShotButton.Text = texts.AddScreenshot;
        removeShotButton.Text = texts.RemoveScreenshot;
        sendButton.Text = texts.Send;
        cancelButton.Text = texts.Cancel;

        var anonymous = telemetry.Reports.WouldBeAnonymous;
        var notice = texts.ReportNotice + (anonymous ? "\n\n" + texts.ReportNoticeAnonymous : "");
        noteLabel.Text = anonymous ? texts.NoteAnonymous : texts.NoteLinked;

        policyLink.Text = texts.PolicyLink;
        policyLink.LinkClicked += (_, _) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(texts.PolicyUrl) { UseShellExecute = true });

        var kindRow = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Margin = new Padding(0, 10, 0, 0) };
        kindRow.Controls.AddRange([new Label { Text = texts.Kind + ":", AutoSize = true, Anchor = AnchorStyles.Left }, kindBox]);
        var shotRow = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Margin = new Padding(0, 4, 0, 0) };
        shotRow.Controls.AddRange([addShotButton, removeShotButton]);
        var shotPreview = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Margin = new Padding(0, 4, 0, 0) };
        shotPreview.Controls.AddRange([thumbnail, shotInfo]);
        var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Right, Margin = new Padding(0, 10, 0, 0) };
        buttons.Controls.AddRange([cancelButton, sendButton]);

        var layout = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Dock = DockStyle.Fill };
        layout.Controls.AddRange([
            new Label { Text = notice, AutoSize = true, MaximumSize = new Size(ContentWidth, 0) },
            policyLink,
            kindRow,
            new Label { Text = texts.Description, AutoSize = true, Margin = new Padding(0, 10, 0, 2) },
            descriptionBox,
            counterLabel,
            new Label { Text = texts.Screenshot, AutoSize = true, Margin = new Padding(0, 6, 0, 0) },
            new Label { Text = texts.ScreenshotNotice, AutoSize = true, MaximumSize = new Size(ContentWidth, 0), ForeColor = SystemColors.GrayText },
            shotRow,
            shotPreview,
            new Label { Text = texts.Preview, AutoSize = true, Margin = new Padding(0, 10, 0, 2) },
            previewBox,
            noteLabel,
            statusLabel,
            buttons,
        ]);
        Controls.Add(layout);
        CancelButton = cancelButton;

        kindBox.SelectedIndexChanged += (_, _) => RebuildPreview();
        descriptionBox.TextChanged += (_, _) => RebuildPreview();
        addShotButton.Click += (_, _) => AddScreenshot();
        removeShotButton.Click += (_, _) => SetScreenshot(null);
        sendButton.Click += async (_, _) => await SendAsync();
        cancelButton.Click += (_, _) => sending?.Cancel();
        RebuildPreview();
    }

    public void SetDescription(string text) => descriptionBox.Text = text;

    public void SetScreenshotForPreview(byte[] png) => SetScreenshot(png);

    private ReportKind Kind => kindBox.SelectedIndex == 1 ? ReportKind.Feature : ReportKind.Bug;

    private void RebuildPreview()
    {
        counterLabel.Text = $"{descriptionBox.TextLength} / {ReportPayload.MaxDescription}";
        reportJson = ReportPayload.Build(Kind, descriptionBox.Text, diagnostics, appVersion, locale);
        previewBox.Text = ReportPayload.Preview(reportJson).ReplaceLineEndings("\r\n");
    }

    private void AddScreenshot()
    {
        if (windows.Count == 0)
        {
            statusLabel.Text = texts.ScreenshotFailed;
            return;
        }
        if (windows.Count == 1)
        {
            _ = CaptureAsync(windows[0]);
            return;
        }
        var menu = new ContextMenuStrip();
        menu.Items.Add(new ToolStripLabel(texts.ChooseWindow));
        foreach (var choice in windows)
        {
            menu.Items.Add(choice.Label, null, async (_, _) => await CaptureAsync(choice));
        }
        menu.Show(addShotButton, new Point(0, addShotButton.Height));
    }

    private async Task CaptureAsync(ReportWindowChoice choice)
    {
        try
        {
            var png = await choice.Capture();
            if (png is null)
            {
                statusLabel.Text = texts.ScreenshotFailed;
                return;
            }
            statusLabel.Text = "";
            SetScreenshot(png);
        }
        catch (Exception e) when (e is InvalidOperationException or System.Runtime.InteropServices.COMException or ArgumentException)
        {
            statusLabel.Text = texts.ScreenshotFailed;
        }
    }

    private void SetScreenshot(byte[]? png)
    {
        screenshot = png;
        thumbnail.Image?.Dispose();
        thumbnail.Image = null;
        if (png is not null)
        {
            using var decoded = new Bitmap(new MemoryStream(png));
            thumbnail.Image = new Bitmap(decoded);
            shotInfo.Text = $"PNG · {decoded.Width}×{decoded.Height} · {png.Length / 1024} KB";
        }
        thumbnail.Visible = shotInfo.Visible = removeShotButton.Visible = png is not null;
    }

    private async Task SendAsync()
    {
        if (finished)
        {
            Close();
            return;
        }
        if (descriptionBox.Text.Trim().Length == 0)
        {
            statusLabel.Text = texts.DescriptionNeeded;
            return;
        }
        if (MessageBox.Show(this, texts.ConfirmSend, texts.ReportTitle, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes)
        {
            return;
        }
        SetBusy(true);
        sending = new CancellationTokenSource();
        ReportOutcome outcome;
        try
        {
            outcome = await telemetry.Reports.SendNewAsync(reportJson, screenshot, sending.Token);
        }
        finally
        {
            sending.Dispose();
            sending = null;
        }
        if (IsDisposed)
        {
            return;
        }
        statusLabel.Text = Describe(outcome);
        if (outcome.Result is ReportResult.Sent or ReportResult.Queued)
        {
            finished = true;
            sendButton.Text = texts.Close;
            cancelButton.Visible = false;
        }
        SetBusy(false);
    }

    private string Describe(ReportOutcome outcome) => outcome.Result switch
    {
        ReportResult.Sent => outcome.Code is { } code ? string.Format(CultureInfo.CurrentCulture, texts.SentWithCode, code) : texts.SentWithoutCode,
        ReportResult.Queued => string.Format(CultureInfo.CurrentCulture, texts.Queued, outcome.Detail),
        ReportResult.QueueFull => texts.QueueFull,
        ReportResult.TooLarge => texts.TooLarge,
        ReportResult.NotSaved => string.Format(CultureInfo.CurrentCulture, texts.NotSaved, outcome.Detail),
        ReportResult.Rejected => string.Format(CultureInfo.CurrentCulture, texts.Rejected, outcome.Detail),
        _ => "",
    };

    private void SetBusy(bool busy)
    {
        sendButton.Enabled = !busy;
        descriptionBox.ReadOnly = busy || finished;
        kindBox.Enabled = addShotButton.Enabled = removeShotButton.Enabled = !busy && !finished;
    }
}
