using System.Diagnostics;
using System.Globalization;
using OsbManager.Core;
using OsbManager.Core.Telemetry;

namespace OsbManager.UI;

internal sealed class PrivacyForm : Form
{
    private const int ContentWidth = 560;

    private readonly TelemetryService telemetry;
    private readonly PrivacyTexts texts;
    private readonly CheckBox usageBox = new() { AutoSize = true, Margin = new Padding(0, 4, 0, 2) };
    private readonly CheckBox charactersBox = new() { AutoSize = true, Margin = new Padding(0, 10, 0, 2) };
    private readonly Label consentLabel = new() { AutoSize = true, MaximumSize = new Size(ContentWidth, 0), ForeColor = SystemColors.GrayText, Margin = new Padding(0, 10, 0, 6) };
    private readonly Button showButton = new() { AutoSize = true };
    private readonly Button downloadButton = new() { AutoSize = true };
    private readonly Button deleteButton = new() { AutoSize = true };
    private readonly TextBox sentBox = new()
    {
        Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, Visible = false,
        Width = ContentWidth, Height = 170, Font = new Font(FontFamily.GenericMonospace, 8.5F), Margin = new Padding(0, 6, 0, 6),
    };
    private readonly TextBox installBox = new() { ReadOnly = true, Width = 330 };
    private readonly Button copyButton = new() { AutoSize = true };
    private readonly Label installLabel = new() { AutoSize = true, Anchor = AnchorStyles.Left };
    private readonly Label lastSentLabel = new() { AutoSize = true, MaximumSize = new Size(ContentWidth, 0), Margin = new Padding(0, 6, 0, 0) };
    private readonly Label messageLabel = new() { AutoSize = true, UseMnemonic = false, MaximumSize = new Size(ContentWidth, 0), Margin = new Padding(0, 4, 0, 0) };
    private readonly LinkLabel policyLink = new() { AutoSize = true, Margin = new Padding(0, 6, 0, 0) };
    private readonly FlowLayoutPanel kvkkLinks = new() { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Margin = new Padding(0, 2, 0, 0) };
    private readonly System.Windows.Forms.Timer refreshTimer = new() { Interval = 2000 };
    private bool refreshing;

    public PrivacyForm(TelemetryService telemetry, PrivacyTexts texts)
    {
        this.telemetry = telemetry;
        this.texts = texts;
        Text = $"{AppIdentity.Name} · {texts.PrivacyTitle}";
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

        usageBox.Text = texts.UsageLabel;
        charactersBox.Text = texts.CharactersLabel;
        showButton.Text = texts.ShowSent;
        downloadButton.Text = texts.DownloadData;
        deleteButton.Text = texts.DeleteData;
        copyButton.Text = texts.Copy;
        installLabel.Text = texts.InstallId + ":";
        policyLink.Text = texts.PolicyLine;
        policyLink.LinkClicked += (_, _) => OpenUrl(texts.PolicyUrl);
        AddKvkkLink(texts.KvkkNoticeLink, texts.KvkkNoticeUrl);
        AddKvkkLink(texts.KvkkConsentLink, texts.KvkkConsentUrl);

        var close = new Button { Text = texts.Close, AutoSize = true, DialogResult = DialogResult.OK, Anchor = AnchorStyles.Right, Margin = new Padding(0, 12, 0, 0) };
        var actions = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Margin = Padding.Empty };
        actions.Controls.AddRange([showButton, downloadButton, deleteButton]);
        var install = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Margin = new Padding(0, 10, 0, 0) };
        install.Controls.AddRange([installLabel, installBox, copyButton]);

        var layout = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Dock = DockStyle.Fill };
        layout.Controls.AddRange([
            usageBox,
            Help(texts.UsageHelp),
            charactersBox,
            Help(texts.CharactersHelp),
            consentLabel,
            actions,
            sentBox,
            install,
            lastSentLabel,
            messageLabel,
            policyLink,
            kvkkLinks,
            close,
        ]);
        Controls.Add(layout);
        AcceptButton = close;
        CancelButton = close;

        usageBox.CheckedChanged += (_, _) => OnUsageChanged();
        charactersBox.CheckedChanged += (_, _) => OnCharactersChanged();
        showButton.Click += (_, _) => ShowSent();
        deleteButton.Click += async (_, _) => await DeleteAsync();
        downloadButton.Click += async (_, _) => await DownloadAsync();
        copyButton.Click += (_, _) => CopyInstallId();
        refreshTimer.Tick += (_, _) => RefreshView();
        refreshTimer.Start();
        RefreshView();
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        refreshTimer.Stop();
        refreshTimer.Dispose();
        base.OnFormClosed(e);
    }

    private static void OpenUrl(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });

    private void AddKvkkLink(string text, string url)
    {
        var link = new LinkLabel { AutoSize = true, Text = text, Margin = new Padding(0, 0, 14, 0) };
        link.LinkClicked += (_, _) => OpenUrl(url);
        kvkkLinks.Controls.Add(link);
    }

    private static Label Help(string text) => new() { Text = text, AutoSize = true, MaximumSize = new Size(ContentWidth, 0), Margin = new Padding(20, 0, 0, 0) };

    private void RefreshView()
    {
        var state = telemetry.Privacy.State;
        refreshing = true;
        usageBox.Checked = state.Granted;
        charactersBox.Enabled = state.Granted;
        charactersBox.Checked = state.CharactersConsent;
        refreshing = false;
        consentLabel.Text = state.Granted && state.UsageConsentedAt is { } at
            ? string.Format(CultureInfo.CurrentCulture, texts.ConsentRecord, state.UsageConsentTextId ?? "-", at.ToLocalTime().ToString("g", CultureInfo.CurrentCulture))
            : texts.NoConsentRecord;
        var installId = state.InstallId ?? telemetry.FailedDeletionInstallId ?? "";
        if (installBox.Text != installId)
        {
            installBox.Text = installId;
        }
        copyButton.Enabled = installId.Length > 0;
        showButton.Enabled = state.Granted;
        downloadButton.Enabled = state.Granted && state.Registered;
        deleteButton.Enabled = state.InstallId is not null;
        installLabel.Visible = installBox.Visible = copyButton.Visible = installId.Length > 0;
        lastSentLabel.Text = $"{texts.LastSent}: {LastSent(state)}";
        lastSentLabel.Visible = state.Granted;
        messageLabel.Text = state.Config?.Message is { } message ? $"{texts.ServerMessage}: {message}" : "";
        messageLabel.Visible = messageLabel.Text.Length > 0;
        if (!state.Granted)
        {
            sentBox.Visible = false;
        }
    }

    private string LastSent(PrivacyState state)
    {
        if (state.LastSentAt is { } at)
        {
            return at.ToLocalTime().ToString("g", CultureInfo.CurrentCulture);
        }
        return state.LastResult == "server unreachable" ? texts.ServerUnreachable : texts.NotSentYet;
    }

    public void ExpandPreview() => ShowSent();

    private async void OnUsageChanged()
    {
        if (refreshing)
        {
            return;
        }
        if (usageBox.Checked)
        {
            telemetry.Accept(characters: false);
            RefreshView();
            return;
        }
        if (MessageBox.Show(this, texts.StopConfirm, texts.PrivacyTitle, MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes)
        {
            RefreshView();
            return;
        }
        await WithdrawAsync();
    }

    private void OnCharactersChanged()
    {
        if (refreshing)
        {
            return;
        }
        telemetry.SetCharacters(charactersBox.Checked);
        RefreshView();
    }

    private async Task WithdrawAsync()
    {
        var pending = telemetry.WithdrawAsync();
        RefreshView();
        if (await pending == DeletionResult.Failed)
        {
            RefreshView();
            MessageBox.Show(this, string.Format(CultureInfo.CurrentCulture, texts.DeleteFailed, PrivacyTexts.PrivacyEmail, telemetry.FailedDeletionInstallId), texts.PrivacyTitle, MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
    }

    private async Task DeleteAsync()
    {
        if (MessageBox.Show(this, texts.DeleteConfirm, texts.DeleteData, MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes)
        {
            return;
        }
        await WithdrawAsync();
    }

    private void ShowSent()
    {
        if (sentBox.Visible)
        {
            sentBox.Visible = false;
            return;
        }
        sentBox.Text = PreviewText();
        sentBox.Visible = true;
    }

    private string PreviewText()
    {
        var sections = new List<string>();
        if (telemetry.PreviewNextPayload() is { } usage)
        {
            sections.Add($"{texts.SentUsageTitle}\r\n{usage}");
        }
        if (telemetry.PreviewNextDiagnostics() is { } diagnostics)
        {
            sections.Add($"{texts.SentDiagnosticsTitle}\r\n{diagnostics}");
        }
        return sections.Count == 0 ? texts.NothingToShow : string.Join("\r\n\r\n", sections).ReplaceLineEndings("\r\n");
    }

    private async Task DownloadAsync()
    {
        using var dialog = new SaveFileDialog { Filter = "JSON (*.json)|*.json", FileName = $"osb-data-{telemetry.Privacy.State.InstallId}.json" };
        if (dialog.ShowDialog(this) != DialogResult.OK)
        {
            return;
        }
        downloadButton.Enabled = false;
        var result = await telemetry.ExportAsync(CancellationToken.None);
        var saved = false;
        if (result.Succeeded)
        {
            try
            {
                await File.WriteAllBytesAsync(dialog.FileName, result.Data);
                saved = true;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
            }
        }
        MessageBox.Show(
            this,
            saved ? string.Format(CultureInfo.CurrentCulture, texts.Saved, dialog.FileName) : texts.DownloadFailed,
            texts.PrivacyTitle,
            MessageBoxButtons.OK,
            saved ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
        RefreshView();
    }

    private void CopyInstallId()
    {
        if (installBox.Text.Length > 0)
        {
            Clipboard.SetText(installBox.Text);
        }
    }
}
