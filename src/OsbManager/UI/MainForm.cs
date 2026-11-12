using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using OsbManager.Browser;
using OsbManager.Core;
using OsbManager.Core.Accounts;
using OsbManager.Core.Rendering;
using OsbManager.Core.Scripts;
using OsbManager.Core.Status;
using OsbManager.Core.Telemetry;
using OsbManager.Core.Telemetry.Diagnostics;
using OsbManager.Core.Updates;
using Format = OsbManager.Core.Status.Format;

namespace OsbManager.UI;

internal sealed class MainForm : Form
{
    private readonly AppServices services;
    private readonly StartupOptions options;
    private readonly ShowcaseFeed? showcase;
    private readonly string? runtimeVersion = BrowserHost.RuntimeVersion();
    private readonly Dictionary<string, GameWindow> windows = new(StringComparer.Ordinal);
    private readonly Dictionary<string, RendererRecovery> recoveries = new(StringComparer.Ordinal);
    private readonly Dictionary<string, PageHealth> pageHealth = new(StringComparer.Ordinal);
    private readonly WindowRestarts restarting = new();
    private readonly TreeView accountTree = new() { Dock = DockStyle.Fill, HideSelection = false, FullRowSelect = true };
    private readonly TreeNode rootNode = new("Accounts");
    private readonly ListBox logList = new() { Dock = DockStyle.Fill, IntegralHeight = false, HorizontalScrollbar = true };
    private readonly GridView statusGrid = new(
        ("Account", 120, HorizontalAlignment.Left), ("State", 130, HorizontalAlignment.Left), ("Character", 110, HorizontalAlignment.Left),
        ("Region", 70, HorizontalAlignment.Left), ("Level", 50, HorizontalAlignment.Right), ("HP", 50, HorizontalAlignment.Right),
        ("MP", 50, HorizontalAlignment.Right), ("Gold", 110, HorizontalAlignment.Right), ("Return", 55, HorizontalAlignment.Right),
        ("Reverse", 60, HorizontalAlignment.Right), ("Bot", 90, HorizontalAlignment.Left));
    private readonly GridView statsGrid = new(
        ("Account", 120, HorizontalAlignment.Left), ("Character", 110, HorizontalAlignment.Left), ("Hunting", 70, HorizontalAlignment.Right),
        ("Kills", 60, HorizontalAlignment.Right), ("Kills/h", 60, HorizontalAlignment.Right), ("XP", 80, HorizontalAlignment.Right),
        ("XP/h", 80, HorizontalAlignment.Right), ("Gold", 90, HorizontalAlignment.Right), ("Gold/h", 90, HorizontalAlignment.Right),
        ("Deaths", 55, HorizontalAlignment.Right), ("SoX", 50, HorizontalAlignment.Right));
    private readonly GridView soxGrid = new([.. SoxTable.Columns.Select(c => (c.Title, c.Width, HorizontalAlignment.Left))]);
    private readonly GridView memoryGrid = new(
        ("Account", 120, HorizontalAlignment.Left), ("State", 90, HorizontalAlignment.Left), ("Renderer private", 110, HorizontalAlignment.Right),
        ("Renderer working set", 130, HorizontalAlignment.Right), ("JS heap used", 95, HorizontalAlignment.Right),
        ("JS heap total", 95, HorizontalAlignment.Right), ("WebAssembly", 95, HorizontalAlignment.Right));
    private readonly Label memorySummary = new() { Dock = DockStyle.Fill, AutoSize = true, Padding = new Padding(6) };
    private readonly System.Windows.Forms.Timer memoryTimer = new() { Interval = 4000 };
    private readonly TabControl rightTabs = new() { Dock = DockStyle.Fill };
    private readonly TabPage memoryPage = new("Memory");
    private bool memoryBusy;
    private bool closing;
    private readonly ScriptJobs scriptJobs = new();
    private static readonly TimeSpan OsbUpdateFirstDelay = TimeSpan.FromMinutes(1);
    private static readonly TimeSpan OsbUpdateInterval = TimeSpan.FromHours(6);
    private static readonly TimeSpan OsbUpdateBusyRetry = TimeSpan.FromMinutes(1);
    private readonly System.Windows.Forms.Timer osbUpdateTimer = new();
    private readonly OsbAutoUpdate osbUpdate;
    private readonly CheckBox soxMineBox = new() { Text = "Only my characters", AutoSize = true, Checked = true, Margin = new Padding(3, 7, 3, 3) };
    private readonly CheckBox soxHideStarBox = new() { Text = "Hide Star items", AutoSize = true, Margin = new Padding(3, 7, 3, 3) };
    private readonly Label soxSummary = new() { AutoSize = true, Margin = new Padding(12, 9, 3, 3) };
    private readonly DateTime startedAt = DateTime.Now;
    private readonly GridView scriptGrid = new(
        ("Script", 180, HorizontalAlignment.Left), ("Version", 70, HorizontalAlignment.Left), ("Runs on", 200, HorizontalAlignment.Left),
        ("Run at", 100, HorizontalAlignment.Left), ("Notes", 260, HorizontalAlignment.Left)) { CheckBoxes = true };
    private readonly TextBox nameBox = new() { Width = 260 };
    private readonly CheckBox startLightBox = new() { Text = "Start in light mode (no rendering, muted)", AutoSize = true };
    private readonly TextBox loginIdBox = new() { Width = 260, MaxLength = 256 };
    private readonly TextBox passwordBox = new() { Width = 260, MaxLength = 1024, UseSystemPasswordChar = true };
    private readonly TextBox serverBox = new() { Width = 260, MaxLength = 64, PlaceholderText = "game default" };
    private readonly TextBox characterBox = new() { Width = 260, MaxLength = 64, PlaceholderText = "choose it yourself" };
    private readonly CheckBox autoLoginBox = new() { Text = "Log in automatically", AutoSize = true };
    private readonly Label profileLabel = new() { AutoSize = true, ForeColor = SystemColors.GrayText };
    private readonly Label countLabel = new() { AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(12, 9, 3, 3) };
    private readonly Label scriptHint = new() { AutoSize = true, Margin = new Padding(12, 9, 3, 3) };
    private readonly ToolStripStatusLabel footer = new() { Spring = true, TextAlign = ContentAlignment.MiddleLeft };
    private readonly System.Windows.Forms.Timer refreshTimer = new() { Interval = 1000 };
    private readonly StartQueue startQueue = new(TimeSpan.FromSeconds(15));
    private readonly ToolTip toolTip = new();
    private readonly Panel botNotice = new() { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(6), Visible = false };
    private readonly Label botWarning = new() { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(6), ForeColor = Color.Firebrick, Visible = false };
    private readonly Panel privacyPrompt = new() { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(8), Visible = false, BackColor = SystemColors.Info };
    private readonly PrivacyTexts privacyTexts = PrivacyTexts.English;
    private readonly Label privacyLead = new() { AutoSize = true, MaximumSize = new Size(760, 0), Visible = false, Margin = new Padding(3, 4, 3, 2) };
    private readonly Label osbInstallLine = new() { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(6), ForeColor = SystemColors.GrayText, Visible = false };
    private bool botWarningLogged;
    private readonly Panel updatePanel = new() { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(8), Visible = false, BackColor = SystemColors.Info };
    private readonly Label updateText = new() { AutoSize = true, MaximumSize = new Size(760, 0) };
    private readonly FlowLayoutPanel updateButtons = new() { AutoSize = true };
    private readonly UpdateNotice updateNotice = new();
    private DateTime lastLaunch = DateTime.MinValue;
    private bool exitingForUpdate;

    public MainForm(AppServices services, StartupOptions options, ShowcaseFeed? showcase = null)
    {
        this.services = services;
        this.options = options;
        this.showcase = showcase;
        osbUpdate = new OsbAutoUpdate(services.Scripts, services.Http, scriptJobs, () => services.Settings.UpdateOsbAutomatically, options.OsbUrl);
        Text = AppIdentity.Name;
        Icon = AppIcon.Instance;
        ClientSize = new Size(1100, 560);
        MinimumSize = new Size(800, 420);
        StartPosition = FormStartPosition.CenterScreen;

        accountTree.Nodes.Add(rootNode);
        accountTree.AfterSelect += (_, _) => ShowSelectedAccount();
        accountTree.NodeMouseDoubleClick += (_, e) => { if (e.Node?.Tag is Account account) StartOrShow(account, account.StartLight); };
        accountTree.NodeMouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Right && e.Node is { } node)
            {
                accountTree.SelectedNode = node;
                ShowAccountMenu(node.Tag as Account, accountTree, e.Location);
            }
        };
        statusGrid.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Right && statusGrid.GetItemAt(e.X, e.Y) is { Tag: Account account } row)
            {
                row.Selected = true;
                ShowAccountMenu(account, statusGrid, e.Location);
            }
        };        scriptGrid.ItemChecked += OnScriptChecked;

        var leftTabs = new TabControl { Dock = DockStyle.Fill };
        leftTabs.TabPages.Add(Page("Accounts", accountTree));
        leftTabs.TabPages.Add(Page("Log", logList));

        rightTabs.TabPages.Add(Page("Account", BuildEditor()));
        rightTabs.TabPages.Add(Page("Status", statusGrid));
        rightTabs.TabPages.Add(Page("Stats", statsGrid));
        rightTabs.TabPages.Add(Page("SoX", BuildSoxPage()));
        rightTabs.TabPages.Add(Page("Scripts", BuildScriptsPage()));
        memoryPage.Controls.Add(BuildMemoryPage());
        rightTabs.TabPages.Add(memoryPage);
        rightTabs.SelectedIndexChanged += (_, _) => UpdateMemoryTimer();
        memoryTimer.Tick += (_, _) => RefreshMemory();
        Resize += (_, _) => UpdateMemoryTimer();
        VisibleChanged += (_, _) => UpdateMemoryTimer();

        var split = new SplitContainer { Dock = DockStyle.Fill, FixedPanel = FixedPanel.Panel1 };
        split.Panel1.Controls.Add(leftTabs);
        split.Panel2.Controls.Add(rightTabs);

        var bottom = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, Padding = new Padding(6) };
        bottom.Controls.AddRange([
            ButtonFor("+", AddAccount, 32),
            ButtonFor("−", RemoveSelectedAccount, 32),
            ButtonFor("▲", () => MoveSelectedAccount(-1), 32, "Move up (Alt+Up)"),
            ButtonFor("▼", () => MoveSelectedAccount(1), 32, "Move down (Alt+Down)"),
            ButtonFor("Start", () => StartSelected(light: false)),
            ButtonFor("Start light", () => StartSelected(light: true)),
            ButtonFor("Start all light", () => StartAll(light: true)),
            ButtonFor("Close all", () => CloseAll(prompt: true)),
            countLabel,
        ]);

        var statusStrip = new StatusStrip();
        statusStrip.Items.Add(footer);

        Controls.Add(split);
        Controls.Add(bottom);
        BuildPrivacyPrompt();
        Controls.Add(privacyPrompt);
        BuildUpdatePanel();
        Controls.Add(updatePanel);
        Controls.Add(BuildMenu());
        Controls.Add(statusStrip);
        Shown += (_, _) =>
        {
            split.SplitterDistance = 230;
            if (showcase is not null)
            {
                return;
            }
            services.PostToUi = action => { if (!closing && !IsDisposed && IsHandleCreated) { BeginInvoke(action); } };
            services.Telemetry.Capture.RequestPageMemory = RequestPageMemory;
            OnShownStartAccounts();
            _ = InstallOsbThenWatchForUpdatesAsync();
            services.Telemetry.Start();
#if DEBUG
            if (TelemetryTestSwitches.WithdrawAfterSeconds is { } withdrawAfter)
            {
                var withdrawTimer = new System.Windows.Forms.Timer { Interval = withdrawAfter * 1000 };
                withdrawTimer.Tick += (_, _) =>
                {
                    withdrawTimer.Stop();
                    _ = services.Telemetry.WithdrawAsync();
                };
                withdrawTimer.Start();
            }
#endif
            StartUpdates();
        };

        if (runtimeVersion is null)
        {
            services.Log.Error("The Microsoft Edge WebView2 Runtime is not installed.");
        }
        foreach (var entry in services.Log.Recent)
        {
            logList.Items.Add(entry.ToString());
        }
        services.Log.Added += OnLogAdded;
        services.Scripts.Changed += OnScriptsChanged;
        services.Sox.Added += OnSoxAdded;
        services.Sox.Updated += OnSoxAdded;
        soxMineBox.CheckedChanged += (_, _) => RefreshSox();
        soxHideStarBox.Checked = services.Settings.HideStarSox;
        soxHideStarBox.CheckedChanged += (_, _) =>
        {
            services.Settings.HideStarSox = soxHideStarBox.Checked;
            services.Settings.Save();
            RefreshSox();
        };
        refreshTimer.Tick += (_, _) =>
        {
#if DEBUG
            LatencyProbe.Interval("ui_1s", 1000);
#endif
            StartQueued();
            UpdatePerfWindows();
            services.Updates.Busy = startQueue.Count > 0 || DateTime.UtcNow - lastLaunch < TimeSpan.FromSeconds(60);
            services.Renderers.Pump();
            services.Telemetry.TickOsbPerf();
            foreach (var window in windows.Values.ToList())
            {
                window.WatchPage();
            }
            RefreshAll();
        };
        refreshTimer.Start();
#if DEBUG
        if (LatencyProbe.Enabled)
        {
            var probeTimer = new System.Windows.Forms.Timer { Interval = 50 };
            probeTimer.Tick += (_, _) => LatencyProbe.Interval("ui_50ms", 50);
            probeTimer.Start();
        }
#endif

        RebuildTree();
        RefreshScripts();
        RefreshSox();
        RefreshAll();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        memoryTimer.Stop();
        osbUpdateTimer.Stop();
        if (e.CloseReason == CloseReason.UserClosing && !exitingForUpdate && !ConfirmCloseAll("quit"))
        {
            e.Cancel = true;
            UpdateMemoryTimer();
            return;
        }
        closing = true;
        CloseAll(prompt: false);
        services.Telemetry.Stop(TimeSpan.FromSeconds(1));
        refreshTimer.Stop();
        services.Log.Added -= OnLogAdded;
        services.Scripts.Changed -= OnScriptsChanged;
        services.Sox.Added -= OnSoxAdded;
        services.Sox.Updated -= OnSoxAdded;
        services.Updates.Checked -= OnUpdateChecked;
        base.OnFormClosing(e);
    }

    private MenuStrip BuildMenu()
    {
        var menu = new MenuStrip();
        var file = new ToolStripMenuItem("File");
        file.DropDownItems.Add("Open data folder", null, (_, _) => Process.Start(new ProcessStartInfo(services.Paths.Root) { UseShellExecute = true }));
        file.DropDownItems.Add("Clear shared asset cache…", null, (_, _) => ClearCache());
        file.DropDownItems.Add(new ToolStripSeparator());
        file.DropDownItems.Add("Exit", null, (_, _) => Close());
        var accounts = new ToolStripMenuItem("Accounts");
        accounts.DropDownItems.Add(AccountMenu.Add, null, (_, _) => AddAccount());
        accounts.DropDownItems.Add(AccountMenu.Remove, null, (_, _) => RemoveSelectedAccount());
        accounts.DropDownItems.Add(new ToolStripMenuItem(AccountMenu.MoveUp, null, (_, _) => MoveSelectedAccount(-1)) { ShortcutKeyDisplayString = "Alt+Up" });
        accounts.DropDownItems.Add(new ToolStripMenuItem(AccountMenu.MoveDown, null, (_, _) => MoveSelectedAccount(1)) { ShortcutKeyDisplayString = "Alt+Down" });
        accounts.DropDownItems.Add(new ToolStripSeparator());
        accounts.DropDownItems.Add(AccountMenu.Start, null, (_, _) => StartSelected(light: false));
        accounts.DropDownItems.Add(AccountMenu.StartLight, null, (_, _) => StartSelected(light: true));
        accounts.DropDownItems.Add(AccountMenu.StartAll, null, (_, _) => StartAll(light: false));
        accounts.DropDownItems.Add(AccountMenu.StartAllLight, null, (_, _) => StartAll(light: true));
        accounts.DropDownItems.Add(AccountMenu.ToggleLight, null, (_, _) => ToggleSelectedLight());
        accounts.DropDownItems.Add(AccountMenu.Close, null, (_, _) => CloseSelected());
        accounts.DropDownItems.Add(AccountMenu.CloseAll, null, (_, _) => CloseAll(prompt: true));
        var scripts = new ToolStripMenuItem("Scripts");
        scripts.DropDownItems.Add("Add from file…", null, (_, _) => AddScriptFromFile());
        scripts.DropDownItems.Add("Add from URL…", null, (_, _) => AddScriptFromUrl());
        scripts.DropDownItems.Add("Update", null, (_, _) => UpdateScripts());
        scripts.DropDownItems.Add(SettingItem("Update OSB automatically", services.Settings.UpdateOsbAutomatically, on => services.Settings.UpdateOsbAutomatically = on));
        scripts.DropDownItems.Add("Reload open game windows", null, (_, _) => ReloadAll());
        var view = new ToolStripMenuItem("View");
        var frameLimit = new ToolStripMenuItem("Frame rate limit");
        foreach (var fps in AppSettings.FrameLimits)
        {
            var item = new ToolStripMenuItem(fps == 0 ? "No limit (monitor refresh)" : $"{fps} FPS") { Tag = fps, Checked = services.Settings.FrameLimit == fps };
            item.Click += (_, _) => SetFrameLimit(fps, frameLimit);
            frameLimit.DropDownItems.Add(item);
        }
        view.DropDownItems.Add(frameLimit);
        view.DropDownItems.Add(SettingItem("Low memory when a window is minimised", services.Settings.LowMemoryWhenHidden, on =>
        {
            services.Settings.LowMemoryWhenHidden = on;
            foreach (var window in windows.Values)
            {
                window.ApplyMemoryLevel();
            }
        }));
        view.DropDownItems.Add(SettingItem("Restart a window when its renderer cannot start", services.Settings.RestartAfterRendererFailure, on =>
            services.Settings.RestartAfterRendererFailure = on));
        var help = new ToolStripMenuItem("Help");
        help.DropDownItems.Add(privacyTexts.PrivacyMenu, null, (_, _) => OpenPrivacy());
        help.DropDownItems.Add(privacyTexts.ReportMenu, null, (_, _) => OpenReport());
        help.DropDownItems.Add(privacyTexts.UnsentMenu, null, (_, _) => OpenUnsentReports());
        help.DropDownItems.Add(new ToolStripSeparator());
        help.DropDownItems.Add("Check for updates now", null, (_, _) => CheckForUpdatesNow());
        help.DropDownItems.Add(SettingItem("Check for updates", services.Settings.CheckForUpdates, on => services.Settings.CheckForUpdates = on));
        help.DropDownItems.Add(new ToolStripSeparator());
        help.DropDownItems.Add("About", null, (_, _) => AboutBox.Show(this, Application.ProductVersion, runtimeVersion, services.Paths.Root));
        menu.Items.AddRange([file, accounts, scripts, view, help]);
        return menu;
    }

    private ToolStripMenuItem SettingItem(string text, bool value, Action<bool> apply)
    {
        var item = new ToolStripMenuItem(text) { Checked = value, CheckOnClick = true };
        item.CheckedChanged += (_, _) =>
        {
            apply(item.Checked);
            services.Settings.Save();
            services.Log.Info($"{text}: {(item.Checked ? "on" : "off")}.");
        };
        return item;
    }

    private Control BuildMemoryPage()
    {
        var bottom = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, Padding = new Padding(6) };
        bottom.Controls.Add(ButtonFor("Copy memory report", CopyMemoryReport, tip: "Copies a plain text table of the numbers below"));
        var layout = new Panel { Dock = DockStyle.Fill };
        layout.Controls.Add(memoryGrid);
        layout.Controls.Add(memorySummary);
        layout.Controls.Add(bottom);
        memorySummary.Dock = DockStyle.Bottom;
        memoryGrid.BringToFront();
        return layout;
    }

    private bool MemoryViewVisible => rightTabs.SelectedTab == memoryPage && Visible && WindowState != FormWindowState.Minimized;

    private void UpdateMemoryTimer()
    {
        if (!MemoryViewVisible)
        {
            memoryTimer.Stop();
            return;
        }
        if (!memoryTimer.Enabled)
        {
            memoryTimer.Start();
            RefreshMemory();
        }
    }

    private async void RefreshMemory()
    {
        if (memoryBusy || closing || IsDisposed)
        {
            return;
        }
        memoryBusy = true;
        try
        {
            var report = showcase?.Memory ?? await MemoryProbe.CaptureAsync(services.Browser, windows.Values.ToList());
            if (!MemoryViewVisible)
            {
                return;
            }
            memoryGrid.SetRows(report.Accounts.Select(a => new GridRow([
                a.Account,
                MemoryReport.ModeText(a.Light, a.Hidden),
                MemoryReport.Megabytes(a.Renderer?.PrivateBytes),
                MemoryReport.Megabytes(a.Renderer?.WorkingSetBytes),
                MemoryReport.Megabytes(a.JsHeapUsed),
                MemoryReport.Megabytes(a.JsHeapTotal),
                MemoryReport.WasmText(a.WasmBytes, a.WasmMemories),
            ])).ToList());
            memorySummary.Text = string.Join(Environment.NewLine, report.ToText().Split(Environment.NewLine).SkipWhile(line => !line.StartsWith("Game renderers")).Where(line => line.Length > 0));
        }
        catch (Exception e) when (e is InvalidOperationException or ObjectDisposedException or System.IO.IOException or System.Runtime.InteropServices.COMException or System.Text.Json.JsonException)
        {
            if (!closing && !IsDisposed)
            {
                memorySummary.Text = "Could not read the memory numbers: " + e.Message;
            }
        }
        finally
        {
            memoryBusy = false;
        }
    }

    private async void CopyMemoryReport()
    {
        try
        {
            var report = await MemoryProbe.CaptureAsync(services.Browser, windows.Values.ToList());
            Clipboard.SetText(report.ToText());
            services.Log.Info($"Copied the memory report ({report.Accounts.Count} open account(s)).");
        }
        catch (Exception e) when (e is InvalidOperationException or ObjectDisposedException or System.IO.IOException or System.Runtime.InteropServices.ExternalException)
        {
            services.Log.Warn("Could not copy the memory report: " + e.Message);
        }
    }

    private void SetFrameLimit(int fps, ToolStripMenuItem menu)
    {
        services.Settings.FrameLimit = fps;
        services.Settings.Save();
        foreach (ToolStripMenuItem item in menu.DropDownItems)
        {
            item.Checked = (int)item.Tag! == fps;
        }
        foreach (var window in windows.Values)
        {
            window.ApplyFrameLimit();
        }
        services.Log.Info(fps == 0 ? "Frame rate limit off." : $"Frame rate limited to {fps} FPS.");
        Note("info", TrailCodes.SettingsFpsLimit);
    }

    private Control BuildEditor()
    {
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Padding = new Padding(12), AutoScroll = true };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        var save = ButtonFor("Save", SaveSelectedAccount);
        var buttons = new FlowLayoutPanel { AutoSize = true };
        buttons.Controls.AddRange([save, ButtonFor("Start", () => StartSelected(light: false)), ButtonFor("Start light", () => StartSelected(light: true))]);
        var passwordRow = new FlowLayoutPanel { AutoSize = true, Margin = Padding.Empty };
        passwordRow.Controls.AddRange([passwordBox, ButtonFor("Forget password", ForgetSelectedPassword)]);
        var row = 0;
        void Add(string label, Control control, int top = 0)
        {
            if (label.Length > 0)
            {
                layout.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(3, 6 + top, 12, 3) }, 0, row);
            }
            control.Margin = new Padding(3, 3 + top, 3, 3);
            layout.Controls.Add(control, 1, row++);
        }
        Add("Name", nameBox);
        Add("", startLightBox);
        Add("Login ID", loginIdBox, 12);
        Add("Password", passwordRow);
        Add("Server", serverBox);
        Add("Character", characterBox);
        Add("", autoLoginBox);
        Add("", profileLabel, 6);
        Add("", buttons);
        Add("", new Label
        {
            AutoSize = true,
            MaximumSize = new Size(600, 0),
            Text = "Each account runs in its own browser profile: cookies, local storage and the game's own cache stay separate. " +
                "The game's pack files are downloaded once and shared by every account.\n\n" +
                "Automatic login types the saved login ID and password into the game's login screen, picks the server and enters the character. " +
                "The password is encrypted with Windows (DPAPI) for your Windows user and is sent only to the opensro.online page. " +
                "Leave Server empty for the game's default and Character empty to choose it yourself. " +
                "To resume hunting after an automatic login, turn on the bot's \"Start the bot when this character enters the game\".",
        }, 12);
        return layout;
    }

    private Control BuildSoxPage()
    {
        var panel = new Panel { Dock = DockStyle.Fill };
        var bar = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, Padding = new Padding(3) };
        bar.Controls.AddRange([soxMineBox, soxHideStarBox, ButtonFor("Clear list", ClearSox), soxSummary]);
        panel.Controls.Add(soxGrid);
        panel.Controls.Add(bar);
        return panel;
    }

    private void RefreshSox()
    {
        var drops = SoxTable.Visible(services.Sox.Drops, soxMineBox.Checked, soxHideStarBox.Checked);
        soxGrid.SetRows(drops.Select(d => new GridRow(SoxTable.Cells(d), d, Bold: d.Seal == "Sun")).ToList());
        soxSummary.Text = SoxTable.Summary(drops, soxMineBox.Checked, soxHideStarBox.Checked);
    }

    private void OnSoxAdded(SoxDrop drop)
    {
        if (IsDisposed || !IsHandleCreated)
        {
            return;
        }
        BeginInvoke(RefreshSox);
    }

    private void ClearSox()
    {
        if (MessageBox.Show(this, "Clear the SoX list?", Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
        {
            services.Sox.Clear();
            RefreshSox();
        }
    }

    private Control BuildScriptsPage()
    {
        var panel = new Panel { Dock = DockStyle.Fill };
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, Padding = new Padding(3) };
        buttons.Controls.AddRange([
            ButtonFor("Add file…", AddScriptFromFile),
            ButtonFor("Add from URL…", AddScriptFromUrl),
            ButtonFor("Update", UpdateScripts),
            ButtonFor("Remove", RemoveSelectedScript),
            ButtonFor("Reload game windows", ReloadAll),
            scriptHint,
        ]);
        BuildBotNotice();
        panel.Controls.Add(scriptGrid);
        panel.Controls.Add(buttons);
        panel.Controls.Add(botWarning);
        panel.Controls.Add(botNotice);
        panel.Controls.Add(osbInstallLine);
        return panel;
    }

    private void OnShownStartAccounts()
    {
        foreach (var name in options.Start)
        {
            var account = services.Accounts.Accounts.FirstOrDefault(a => string.Equals(a.Name, name, StringComparison.OrdinalIgnoreCase));
            if (account is null && AccountStore.NameProblem(name, services.Accounts.Accounts, null) is null)
            {
                account = services.Accounts.Add(name);
                RebuildTree();
            }
            if (account is not null)
            {
                StartOrShow(account, options.StartLight || account.StartLight);
            }
        }
    }

    private AccountMenuState StateOf(Account account) =>
        ViewOf(account) is not null ? AccountMenuState.Open : startQueue.Contains(account) ? AccountMenuState.Queued : AccountMenuState.Closed;

    private void ShowAccountMenu(Account? account, Control owner, Point at)
    {
        var entries = account is null ? AccountMenu.ForRoot() : AccountMenu.ForAccount(account, StateOf(account));
        var menu = new ContextMenuStrip();
        foreach (var entry in entries)
        {
            if (entry.SeparatorBefore)
            {
                menu.Items.Add(new ToolStripSeparator());
            }
            var item = new ToolStripMenuItem(entry.Text) { Enabled = entry.Enabled };
            item.Click += (_, _) => RunAccountMenuItem(entry);
            menu.Items.Add(item);
        }
        menu.Closed += (_, _) => BeginInvoke(menu.Dispose);
        menu.Show(owner, at);
    }

    private void RunAccountMenuItem(AccountMenuItem entry)
    {
        var account = entry.Target;
        switch (entry.Action)
        {
            case AccountMenuAction.Add:
                AddAccount();
                break;
            case AccountMenuAction.StartAll:
                StartAll(light: false);
                break;
            case AccountMenuAction.StartAllLight:
                StartAll(light: true);
                break;
            case AccountMenuAction.CloseAll:
                CloseAll(prompt: true);
                break;
            case AccountMenuAction.Start when account is not null:
                StartOrShow(account, light: false);
                break;
            case AccountMenuAction.StartLight when account is not null:
                StartOrShow(account, light: true);
                break;
            case AccountMenuAction.ShowWindow when account is not null:
                StartOrShow(account, account.StartLight);
                break;
            case AccountMenuAction.ReloadWindow when account is not null:
                ReloadAccountWindow(account);
                break;
            case AccountMenuAction.Close when account is not null:
                CloseAccount(account);
                break;
            case AccountMenuAction.CancelStart when account is not null:
                CancelStart(account);
                break;
            case AccountMenuAction.ToggleLight when account is not null:
                ToggleLight(account);
                break;
            case AccountMenuAction.MoveUp when account is not null:
                MoveAccount(account, -1);
                break;
            case AccountMenuAction.MoveDown when account is not null:
                MoveAccount(account, 1);
                break;
            case AccountMenuAction.Remove when account is not null:
                RemoveAccount(account);
                break;
        }
    }

    private Account? SelectedAccount => accountTree.SelectedNode?.Tag as Account;

    private void StartSelected(bool light)
    {
        if (SelectedAccount is { } account)
        {
            StartOrShow(account, light);
        }
        else
        {
            MessageBox.Show(this, "Select an account first.", Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
    }

    private void StartOrShow(Account account, bool light)
    {
        if (windows.TryGetValue(account.Id, out var open))
        {
            if (open.WindowState == FormWindowState.Minimized)
            {
                open.WindowState = FormWindowState.Normal;
            }
            open.Activate();
            return;
        }
        if (runtimeVersion is null)
        {
            MessageBox.Show(this, "Install the Microsoft Edge WebView2 Runtime, then start the account again.", Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        if (!startQueue.Contains(account))
        {
            startQueue.Add(account, light);
            if (startQueue.Count > 1 || startQueue.WaitFor(account) > TimeSpan.Zero)
            {
                services.Log.Info($"{account.Name}: starts in {Math.Ceiling(startQueue.WaitFor(account)!.Value.TotalSeconds):0} s, after the windows before it.");
            }
        }
        StartQueued();
    }

    private void StartQueued()
    {
        if (startQueue.TakeDue() is { } next)
        {
            Launch(next.Account, next.Light);
        }
    }

    private void Launch(Account account, bool light)
    {
        if (windows.ContainsKey(account.Id) || !services.Accounts.Accounts.Contains(account))
        {
            return;
        }
        if (!recoveries.TryGetValue(account.Id, out var recovery))
        {
            recovery = recoveries[account.Id] = new RendererRecovery();
        }
        if (!pageHealth.TryGetValue(account.Id, out var health))
        {
            health = pageHealth[account.Id] = new PageHealth();
        }
        var window = new GameWindow(services, account, light, recovery, health);
        window.RestartRequested += (_, _) => RestartWindow(window);
        window.FormClosed += (_, _) =>
        {
            windows.Remove(account.Id);
            var restart = restarting.TakeOnClose(account.Id, closing);
            if (!restart)
            {
                recoveries.Remove(account.Id);
                pageHealth.Remove(account.Id);
            }
            services.Log.Info($"{account.Name}: closed{(restart ? " for a restart" : "")}.");
            Note("info", TrailCodes.WindowClosed, account);
            if (restart)
            {
                StartOrShow(account, window.Light);
            }
            RefreshAll();
        };
        windows[account.Id] = window;
        lastLaunch = DateTime.UtcNow;
        services.Log.Info($"{account.Name}: starting{(light ? " in light mode" : "")}.");
        Note("info", TrailCodes.WindowStart, account);
        window.Show();
        RefreshAll();
    }

    private void Note(string level, string code, Account? account = null)
    {
        if (services.Telemetry.Diagnostics.Recording)
        {
            services.Telemetry.Capture.Trail(level, code, account is null ? null : services.Ordinals.Of(account.Id));
        }
    }

    private void UpdatePerfWindows()
    {
        if (!services.Telemetry.Diagnostics.Recording)
        {
            return;
        }
        var open = windows.Values;
        services.PerfWindows = new PerfWindows(open.Count, open.Count(w => w.Light), open.Count(w => w.Hidden), open.Count(w => w.InGame));
    }

    private void RequestPageMemory()
    {
        if (closing || IsDisposed || !IsHandleCreated || !services.Telemetry.Diagnostics.Recording)
        {
            return;
        }
        BeginInvoke(() =>
        {
            void OnIdle(object? sender, EventArgs e)
            {
                Application.Idle -= OnIdle;
                ReadPageMemoryForPerf();
            }
            Application.Idle += OnIdle;
        });
    }

    private async void ReadPageMemoryForPerf()
    {
        if (closing || IsDisposed || !services.Telemetry.Diagnostics.Recording)
        {
            return;
        }
        try
        {
            var open = windows.Values.ToList();
            var reads = await Task.WhenAll(open.Select(w => w.ReadPageMemoryAsync())).WaitAsync(TimeSpan.FromSeconds(10));
            const double megabyte = 1024 * 1024;
            services.Telemetry.Perf.SetPageMemory(
                reads.Where(r => r.JsHeapUsed is not null).Select(r => r.JsHeapUsed!.Value / megabyte).ToList(),
                reads.Where(r => r.JsHeapTotal is not null).Select(r => r.JsHeapTotal!.Value / megabyte).ToList(),
                reads.Where(r => r.WasmBytes is not null).Select(r => r.WasmBytes!.Value / megabyte).ToList());
        }
        catch (TimeoutException)
        {
        }
    }

    private void RestartWindow(GameWindow window)
    {
        if (closing || !windows.TryGetValue(window.Account.Id, out var open) || open != window)
        {
            return;
        }
        if (restarting.Request(window.Account.Id))
        {
            BeginInvoke(window.CloseWithoutPrompt);
        }
    }

    private void StartAll(bool light)
    {
        var closed = services.Accounts.Accounts.Where(a => !windows.ContainsKey(a.Id) && !startQueue.Contains(a)).ToList();
        if (closed.Count == 0)
        {
            return;
        }
        services.Log.Info($"Starting {closed.Count} account{(closed.Count == 1 ? "" : "s")}{(light ? " in light mode" : "")}, one every 15 s.");
        foreach (var account in closed)
        {
            StartOrShow(account, light);
        }
    }

    private void MoveSelectedAccount(int offset)
    {
        if (SelectedAccount is { } account)
        {
            MoveAccount(account, offset);
        }
    }

    private void MoveAccount(Account account, int offset)
    {
        if (services.Accounts.Move(account, offset))
        {
            startQueue.SortBy(services.Accounts.Accounts);
            RebuildTree();
        }
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (accountTree.Focused && keyData is (Keys.Alt | Keys.Up) or (Keys.Alt | Keys.Down))
        {
            MoveSelectedAccount((keyData & Keys.KeyCode) == Keys.Up ? -1 : 1);
            return true;
        }
        if (keyData is Keys.Apps or (Keys.Shift | Keys.F10))
        {
            if (accountTree.Focused && accountTree.SelectedNode is { } node)
            {
                ShowAccountMenu(node.Tag as Account, accountTree, new Point(node.Bounds.Left, node.Bounds.Bottom));
                return true;
            }
            if (statusGrid.Focused && statusGrid.SelectedItems.Count > 0 && statusGrid.SelectedItems[0] is { Tag: Account account } row)
            {
                ShowAccountMenu(account, statusGrid, new Point(row.Bounds.Left, row.Bounds.Bottom));
                return true;
            }
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    private void ToggleSelectedLight()
    {
        if (SelectedAccount is { } account)
        {
            ToggleLight(account);
        }
    }

    private void ToggleLight(Account account)
    {
        if (windows.TryGetValue(account.Id, out var window))
        {
            window.SetLight(!window.Light);
            return;
        }
        account.StartLight = !account.StartLight;
        services.Accounts.Save();
        services.Log.Info($"{account.Name}: {(account.StartLight ? "starts in light mode" : "starts with rendering on")}.");
        if (SelectedAccount == account)
        {
            ShowSelectedAccount();
        }
        RefreshAll();
    }

    private void CloseSelected()
    {
        if (SelectedAccount is { } account)
        {
            CloseAccount(account);
        }
    }

    private void CloseAccount(Account account)
    {
        if (windows.TryGetValue(account.Id, out var window))
        {
            window.Close();
        }
    }

    private void ReloadAccountWindow(Account account)
    {
        if (windows.TryGetValue(account.Id, out var window))
        {
            window.ReloadPage();
        }
    }

    private void CancelStart(Account account)
    {
        if (startQueue.Remove(account))
        {
            services.Log.Info($"{account.Name}: start cancelled.");
            RefreshAll();
        }
    }

    private void CloseAll(bool prompt)
    {
        if (prompt && !ConfirmCloseAll("close"))
        {
            return;
        }
        startQueue.Clear();
        restarting.Clear();
        foreach (var window in windows.Values.ToList())
        {
            window.CloseWithoutPrompt();
        }
    }

    private bool ConfirmCloseAll(string verb)
    {
        var inGame = windows.Values.Count(w => w.InGame);
        if (inGame == 0)
        {
            return true;
        }
        var question = $"{inGame} character{(inGame == 1 ? " is" : "s are")} in the game. {char.ToUpperInvariant(verb[0])}{verb[1..]} all game windows?";
        return MessageBox.Show(this, question, Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes;
    }

    private void ReloadAll()
    {
        foreach (var window in windows.Values)
        {
            window.ReloadPage();
        }
    }

    private void AddAccount()
    {
        var name = Prompt.Ask(this, "Add account", "Account name (shown in this app only):", "",
            text => AccountStore.NameProblem(text, services.Accounts.Accounts, null));
        if (name is null)
        {
            return;
        }
        var account = services.Accounts.Add(name);
        services.Log.Info($"{account.Name}: added.");
        services.LearnTerms();
        RebuildTree();
        SelectAccount(account);
    }

    private void RemoveSelectedAccount()
    {
        if (SelectedAccount is { } account)
        {
            RemoveAccount(account);
        }
    }

    private async void RemoveAccount(Account account)
    {
        startQueue.Remove(account);
        if (windows.ContainsKey(account.Id))
        {
            MessageBox.Show(this, $"Close {account.Name}'s game window first.", Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        var question = $"Remove {account.Name}?\n\nIts browser data (cookies, saved logins, local storage and the game's own cache for this account) is deleted as well. This cannot be undone.";
        if (MessageBox.Show(this, question, Text, MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes)
        {
            return;
        }
        services.Accounts.Remove(account);
        RebuildTree();
        try
        {
            await services.Browser.DeleteProfileAsync(Handle, account.ProfileName);
            services.Log.Info($"{account.Name}: removed with its browser data.");
        }
        catch (Exception e)
        {
            services.Log.Error($"{account.Name}: removed, but its browser data could not be deleted (profile {account.ProfileName})", e);
        }
    }

    private void SaveSelectedAccount()
    {
        if (SelectedAccount is not { } account)
        {
            return;
        }
        var login = new LoginDetails(loginIdBox.Text, passwordBox.Text.Length > 0 ? passwordBox.Text : null, serverBox.Text, characterBox.Text, autoLoginBox.Checked);
        var problem = AccountStore.NameProblem(nameBox.Text, services.Accounts.Accounts, account)
            ?? AccountStore.LoginProblem(login, account.HasCredentials);
        if (problem is not null)
        {
            MessageBox.Show(this, problem, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        account.StartLight = startLightBox.Checked;
        services.Accounts.Rename(account, nameBox.Text);
        services.Accounts.UpdateLogin(account, login, services.Protector);
        services.LearnTerms();
        services.Log.Info($"{account.Name}: settings saved{(account.AutoLogin ? " (automatic login on)" : "")}.");
        if (windows.TryGetValue(account.Id, out var window))
        {
            window.SendAutoLogin();
        }
        RebuildTree();
        SelectAccount(account);
    }

    private void ForgetSelectedPassword()
    {
        if (SelectedAccount is not { } account || !account.HasCredentials)
        {
            return;
        }
        services.Accounts.ClearPassword(account);
        services.Log.Info($"{account.Name}: saved password removed; automatic login off.");
        if (windows.TryGetValue(account.Id, out var window))
        {
            window.SendAutoLogin();
        }
        ShowSelectedAccount();
    }

    private void ShowSelectedAccount()
    {
        var account = SelectedAccount;
        foreach (var control in new Control[] { nameBox, startLightBox, loginIdBox, passwordBox, serverBox, characterBox, autoLoginBox })
        {
            control.Enabled = account is not null;
        }
        nameBox.Text = account?.Name ?? "";
        startLightBox.Checked = account?.StartLight ?? false;
        loginIdBox.Text = account?.LoginId ?? "";
        passwordBox.Text = "";
        passwordBox.PlaceholderText = account?.HasCredentials == true ? "saved (leave empty to keep it)" : "";
        serverBox.Text = account?.Server ?? "";
        characterBox.Text = account?.Character ?? "";
        autoLoginBox.Checked = account?.AutoLogin ?? false;
        profileLabel.Text = account is null ? "Select an account on the left." : $"Browser profile: {account.ProfileName}";
    }

    private void AddScriptFromFile()
    {
        using var dialog = new OpenFileDialog { Filter = "Userscripts (*.user.js)|*.user.js|JavaScript files (*.js)|*.js", Title = "Add userscript" };
        if (dialog.ShowDialog(this) != DialogResult.OK)
        {
            return;
        }
        try
        {
            if (new FileInfo(dialog.FileName).Length > ScriptStore.MaxScriptBytes)
            {
                throw new InvalidDataException("The script is too large.");
            }
            var script = services.Scripts.Install(File.ReadAllText(dialog.FileName), null);
            services.Log.Info($"Installed {script.Meta.Name} {script.Meta.Version} from {Path.GetFileName(dialog.FileName)}.");
        }
        catch (Exception e) when (e is IOException or FormatException or InvalidDataException or UnauthorizedAccessException)
        {
            MessageBox.Show(this, e.Message, "Add userscript", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private async void AddScriptFromUrl()
    {
        var url = Prompt.Ask(this, "Add userscript", "Script address (https://…/*.user.js):", options.OsbUrl ?? BotScripts.OsbUrl,
            text => Uri.TryCreate(text.Trim(), UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps ? null : "Use an https:// address.");
        if (url is null)
        {
            return;
        }
        var job = scriptJobs.Begin();
        try
        {
            var script = await services.Scripts.InstallFromUrlAsync(url, services.Http);
            services.Log.Info($"Installed {script.Meta.Name} {script.Meta.Version} from {url}.");
        }
        catch (Exception e)
        {
            services.Log.Error($"Could not install {url}", e);
            Note("error", TrailCodes.ScriptInstallFailed);
            MessageBox.Show(this, e.Message, "Add userscript", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            job.Dispose();
        }
    }

    private async void UpdateScripts()
    {
        var selected = scriptGrid.SelectedItems.Cast<ListViewItem>().Select(i => i.Tag).OfType<InstalledScript>().ToList();
        var targets = selected.Count > 0 ? selected : services.Scripts.Scripts.ToList();
        var job = scriptJobs.Begin();
        try
        {
            foreach (var script in targets)
            {
                if (script.UpdateSource is not { } source)
                {
                    services.Log.Warn($"{script.Meta.Name} has no download address; add the new file instead.");
                    continue;
                }
                try
                {
                    var before = script.Meta.Version;
                    var updated = await services.Scripts.InstallFromUrlAsync(source, services.Http);
                    services.Log.Info(before == updated.Meta.Version
                        ? $"{updated.Meta.Name} is up to date ({before})."
                        : $"Updated {updated.Meta.Name} from {before} to {updated.Meta.Version}.");
                }
                catch (Exception e)
                {
                    services.Log.Error($"Could not update {script.Meta.Name}", e);
                    Note("error", TrailCodes.ScriptUpdateFailed);
                }
            }
        }
        finally
        {
            job.Dispose();
        }
    }

    private void RemoveSelectedScript()
    {
        foreach (var script in scriptGrid.SelectedItems.Cast<ListViewItem>().Select(i => i.Tag).OfType<InstalledScript>().ToList())
        {
            if (MessageBox.Show(this, $"Remove {script.Meta.Name}?", Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
            {
                services.Scripts.Remove(script);
                services.Log.Info($"Removed {script.Meta.Name}.");
            }
        }
    }

    private void OnScriptChecked(object? sender, ItemCheckedEventArgs e)
    {
        if (!scriptGrid.Syncing && e.Item.Tag is InstalledScript script && script.Enabled != e.Item.Checked)
        {
            services.Scripts.SetEnabled(script, e.Item.Checked);
        }
    }

    private void ClearCache()
    {
        if (windows.Count > 0)
        {
            MessageBox.Show(this, "Close all game windows first.", Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        if (MessageBox.Show(this, "Delete the shared game asset cache? Accounts download the files again on their next start.", Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
        {
            services.Cache.Clear();
            services.Log.Info("Cleared the shared asset cache.");
            RefreshAll();
        }
    }

    private void RebuildTree()
    {
        var selected = SelectedAccount;
        accountTree.BeginUpdate();
        rootNode.Nodes.Clear();
        foreach (var account in services.Accounts.Accounts)
        {
            rootNode.Nodes.Add(new TreeNode(account.Name) { Tag = account, Name = account.Id });
        }
        rootNode.Expand();
        accountTree.EndUpdate();
        if (selected is not null)
        {
            SelectAccount(selected);
        }
        ShowSelectedAccount();
        RefreshAll();
    }

    private void SelectAccount(Account account)
    {
        var node = rootNode.Nodes.Find(account.Id, searchAllChildren: false).FirstOrDefault();
        if (node is not null)
        {
            accountTree.SelectedNode = node;
        }
    }

    private void RefreshAll()
    {
        var privacy = services.Telemetry.Privacy.State;
        privacyPrompt.Visible = privacy.NeedsAnswer;
        privacyLead.Visible = privacy.SharedBefore;
        foreach (TreeNode node in rootNode.Nodes)
        {
            if (node.Tag is not Account account)
            {
                continue;
            }
            var window = ViewOf(account);
            var open = window is not null;
            var text = open ? $"{account.Name} ●{(window!.Light ? " light" : "")}" : startQueue.Contains(account) ? $"{account.Name} (queued)" : account.Name;
            var color = !open ? SystemColors.GrayText : window!.InGame ? Color.ForestGreen : SystemColors.ControlText;
            if (node.Text != text)
            {
                node.Text = text;
            }
            if (node.ForeColor != color)
            {
                node.ForeColor = color;
            }
        }
        statusGrid.SetRows(services.Accounts.Accounts.Select(StatusRow).ToList());
        statsGrid.SetRows(StatsRows());
        var inGame = OpenViews.Count(w => w.InGame);
        countLabel.Text = $"{inGame}/{services.Accounts.Accounts.Count} in game · {OpenViews.Count()} open";
        countLabel.ForeColor = inGame > 0 ? Color.ForestGreen : SystemColors.ControlText;

        var cache = showcase?.Cache ?? services.Cache.Counters;
        var bot = OpenViews.Select(w => w.Status?.BotVersion).FirstOrDefault(v => v is not null);
        footer.Text = $"Bot {bot ?? "—"} · shared cache {Format.Bytes(cache.DiskBytes)} ({cache.Packs} packs) · " +
            $"served from disk {Format.Bytes(cache.ServedFromDisk)} · downloaded {Format.Bytes(cache.Downloaded)}" +
            (cache.Failures > 0 ? $" · {cache.Failures} fell back to the browser" : "");
    }

    private IEnumerable<IGameView> OpenViews => showcase is null ? windows.Values : showcase.Windows;

    private IGameView? ViewOf(Account account) => showcase is null
        ? windows.GetValueOrDefault(account.Id)
        : showcase.Windows.FirstOrDefault(w => w.Account.Id == account.Id);

    private GridRow StatusRow(Account account)
    {
        if (ViewOf(account) is not { } window)
        {
            var state = startQueue.WaitFor(account) is { } wait ? $"Starts in {Math.Ceiling(wait.TotalSeconds):0} s" : "Closed";
            return new GridRow([account.Name, state, "", "", "", "", "", "", "", "", ""], account);
        }
        var status = window.Status;
        var bot = status switch
        {
            null => "",
            { BotVersion: null } => "No bot",
            { TownTrip: true } => "Town trip",
            { Hunting: true } => "Hunting",
            _ => "Stopped",
        };
        return new GridRow([
            account.Name,
            window.StateText,
            status?.Character ?? "",
            status?.Region is { } region ? "R" + region : "",
            status?.Level?.ToString() ?? "",
            status?.InWorld == true ? Format.Percent(status.HpPercent) : "",
            status?.InWorld == true ? Format.Percent(status.MpPercent) : "",
            status?.Gold is { } gold ? gold.ToString("N0") : "",
            status?.InWorld == true && status.ReturnScrolls is { } returns ? returns.ToString("N0") : "",
            status?.InWorld == true && status.ReverseScrolls is { } reverses ? reverses.ToString("N0") : "",
            bot,
        ], account);
    }

    private List<GridRow> StatsRows()
    {
        var rows = new List<GridRow>();
        var lines = new List<StatsLine>();
        var sessionStart = showcase?.SessionStart ?? startedAt;
        var drops = services.Sox.Drops.Where(d => d.Ours && d.At >= sessionStart).ToList();
        foreach (var account in services.Accounts.Accounts)
        {
            if (ViewOf(account) is not { } window || window.Status?.Session is not { } session)
            {
                continue;
            }
            var character = window.Status.Character ?? "";
            var sox = drops.Count(d => string.Equals(d.Character, character, StringComparison.OrdinalIgnoreCase));
            rows.Add(new GridRow([
                account.Name,
                character,
                Format.Duration(session.Milliseconds),
                session.Kills.ToString("N0"),
                Format.PerHour(session.Kills, session.Milliseconds),
                Format.Compact(session.Experience),
                Format.PerHour(session.Experience, session.Milliseconds),
                Format.Compact(session.Gold),
                Format.PerHour(session.Gold, session.Milliseconds),
                session.Deaths.ToString("N0"),
                sox.ToString("N0"),
            ], account));
            lines.Add(new StatsLine(session.Milliseconds, session.Kills, session.Experience, session.Gold, session.Deaths, sox));
        }
        if (rows.Count > 1)
        {
            var total = StatsTotals.Sum(lines);
            rows.Add(new GridRow([
                "All characters", "", Format.Duration(total.Milliseconds), total.Kills.ToString("N0"), Format.PerHour(total.KillsPerHour),
                Format.Compact(total.Experience), Format.PerHour(total.ExperiencePerHour), Format.Compact(total.Gold), Format.PerHour(total.GoldPerHour),
                total.Deaths.ToString("N0"), total.Sox.ToString("N0"),
            ], Bold: true));
        }
        return rows;
    }

    private void RefreshScripts()
    {
        scriptGrid.SetRows(services.Scripts.Scripts.Select(s => new GridRow([
            s.Meta.Name,
            s.Meta.Version,
            string.Join(" ", s.Meta.Matches.Concat(s.Meta.Includes)),
            s.Meta.RunAt,
            string.Join("; ", s.Warnings),
        ], s, Checked: s.Enabled)).ToList());
        scriptHint.Text = services.Scripts.Scripts.Count == 0
            ? "No scripts yet. Add from URL suggests the OSB bot."
            : "Changes apply after a game window reloads.";
        RefreshBotNotice();
    }

    private void BuildPrivacyPrompt()
    {
        var title = new Label { AutoSize = true, Text = privacyTexts.FirstRunTitle, Font = new Font(Font, FontStyle.Bold) };
        privacyLead.Text = privacyTexts.FirstRunChangedLead;
        privacyLead.Font = new Font(Font, FontStyle.Italic);
        var text = new Label { AutoSize = true, MaximumSize = new Size(760, 0), Text = privacyTexts.FirstRunText };
        var buttons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Bottom };
        buttons.Controls.AddRange([
            ButtonFor(privacyTexts.FirstRunShare, () => { services.Telemetry.Accept(characters: false); RefreshAll(); }),
            ButtonFor(privacyTexts.FirstRunDecline, DeclinePrivacy),
            PromptLink(privacyTexts.FirstRunWhat, () => OpenPrivacy()),
            PromptLink(privacyTexts.PolicyLink, () => OpenUrl(privacyTexts.PolicyUrl)),
            PromptLink(privacyTexts.KvkkNoticeLink, () => OpenUrl(privacyTexts.KvkkNoticeUrl)),
            PromptLink(privacyTexts.KvkkConsentLink, () => OpenUrl(privacyTexts.KvkkConsentUrl)),
        ]);
        var layout = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, Dock = DockStyle.Fill, WrapContents = false };
        layout.Controls.AddRange([title, privacyLead, text, buttons]);
        var close = new Button { Text = "×", Width = 28, Height = 26, FlatStyle = FlatStyle.Flat, Dock = DockStyle.Right, TabStop = false };
        close.FlatAppearance.BorderSize = 0;
        close.Click += (_, _) => DeclinePrivacy();
        toolTip.SetToolTip(close, privacyTexts.FirstRunClose);
        privacyPrompt.Controls.Add(layout);
        privacyPrompt.Controls.Add(close);
    }

    private void DeclinePrivacy()
    {
        services.Telemetry.Decline();
        RefreshAll();
    }

    private static LinkLabel PromptLink(string text, Action open)
    {
        var link = new LinkLabel { AutoSize = true, Text = text, Margin = new Padding(12, 9, 3, 3) };
        link.LinkClicked += (_, _) => open();
        return link;
    }

    private static void OpenUrl(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });

    private void OpenPrivacy()
    {
        using var form = new PrivacyForm(services.Telemetry, privacyTexts);
        form.ShowDialog(this);
        RefreshAll();
    }

    private void OpenReport()
    {
        var diagnostics = ReportDiagnostics.Build(
            AppServices.AppVersion,
            Environment.OSVersion.Version.ToString(),
            RuntimeInformation.FrameworkDescription,
            windows.Values.Select(w => w.Diagnostics()).ToList(),
            services.Scripts.Scripts.Select(s => new ScriptDiagnostics(s.Meta.Name, s.Meta.Version)).ToList());
        var choices = windows.Values.Select(w => new ReportWindowChoice(w.Account.Name, w.CaptureScreenshotAsync)).ToList();
        using var form = new ReportForm(services.Telemetry, privacyTexts, AppServices.AppVersion, CultureInfo.CurrentUICulture.TwoLetterISOLanguageName, diagnostics, choices);
        form.ShowDialog(this);
    }

    private void OpenUnsentReports()
    {
        using var form = new UnsentReportsForm(services.Telemetry.Outbox, privacyTexts);
        form.ShowDialog(this);
    }

    private void StartUpdates()
    {
        var swap = new ExeSwap(Environment.ProcessPath ?? Application.ExecutablePath);
        if (swap.CleanUp() > 0)
        {
            services.Log.Info("Removed the previous version left by an update.");
        }
        TryDeleteDirectory(services.Paths.Updates);
        services.Updates.Checked += OnUpdateChecked;
        services.Updates.Start();
    }

    private void BuildUpdatePanel()
    {
        var title = new Label { AutoSize = true, Text = "Update available", Font = new Font(Font, FontStyle.Bold) };
        updateButtons.Controls.AddRange([ButtonFor("Install and restart", InstallUpdate), ButtonFor("Later", PostponeUpdate)]);
        var notes = new LinkLabel { AutoSize = true, Text = "Release notes", Margin = new Padding(12, 9, 3, 3) };
        notes.LinkClicked += (_, _) => OpenUrl(updateNotice.Current?.ReleasePage ?? UpdateSource.LatestReleasePage);
        updateButtons.Controls.Add(notes);
        var layout = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, Dock = DockStyle.Fill, WrapContents = false };
        layout.Controls.AddRange([title, updateText, updateButtons]);
        updatePanel.Controls.Add(layout);
    }

    private void OnUpdateChecked(UpdateCheckResult result, bool requestedByUser)
    {
        if (IsDisposed || !IsHandleCreated)
        {
            return;
        }
        BeginInvoke(() =>
        {
            if (result.Offer is { } offer && updateNotice.Offer(offer, requestedByUser))
            {
                ShowUpdateNotice(offer);
#if DEBUG
                if (UpdateTestSwitches.InstallWhenOffered)
                {
                    InstallUpdate();
                }
#endif
            }
        });
    }

    private void ShowUpdateNotice(UpdateOffer offer)
    {
        updateText.Text = $"{offer.Title}: OSB Manager {offer.Version} is ready to install (you have {AppServices.AppVersion}). " +
            "Install and restart closes the game windows, installs the signed update and starts the app again with the same settings.";
        updateButtons.Enabled = true;
        updatePanel.Visible = true;
    }

    private void PostponeUpdate()
    {
        if (updateNotice.Current is { } offer)
        {
            services.Log.Info($"Update to {offer.Version} postponed. It is offered again at the next start.");
        }
        updateNotice.Later();
        updatePanel.Visible = false;
    }

    private async void CheckForUpdatesNow()
    {
        if (services.Updates.Problem is { } problem)
        {
            MessageBox.Show(this, problem, "Check for updates", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        UseWaitCursor = true;
        UpdateCheckResult result;
        try
        {
            result = await services.Updates.CheckNowAsync(CancellationToken.None);
        }
        finally
        {
            UseWaitCursor = false;
        }
        if (result.Status == UpdateCheckStatus.Available)
        {
            return;
        }
        var icon = result.Status == UpdateCheckStatus.Failed ? MessageBoxIcon.Warning : MessageBoxIcon.Information;
        MessageBox.Show(this, result.Message, "Check for updates", MessageBoxButtons.OK, icon);
    }

    private async void InstallUpdate()
    {
        var offer = updateNotice.BeginInstall();
        if (offer is null || services.Updates.Checker is not { } checker)
        {
            return;
        }
        var swap = new ExeSwap(Environment.ProcessPath ?? Application.ExecutablePath);
        if (!ExeSwap.CanWrite(swap.Folder))
        {
            updateNotice.InstallFailed();
            services.Log.Warn($"Cannot install the update: {swap.Folder} is not writable.");
            OfferReleasePage($"OSB Manager cannot write to its folder ({swap.Folder}), so it cannot update itself there.");
            return;
        }
        if (!ConfirmCloseAll("close"))
        {
            updateNotice.InstallFailed();
            return;
        }
        updateButtons.Enabled = false;
        var folder = Path.Combine(services.Paths.Updates, Guid.NewGuid().ToString("N"));
        var swapped = false;
        try
        {
            updateText.Text = $"Downloading OSB Manager {offer.Version}...";
            services.Log.Info($"Downloading the update to {offer.Version}.");
            Note("info", TrailCodes.UpdateDownload);
            var zip = await checker.DownloadAsync(offer, folder, CancellationToken.None);
            services.Log.Info($"The download matches the signed manifest of {offer.Version}.");
            await Task.Run(() => swap.Stage(zip));
            updateText.Text = "Closing the game windows...";
            await CloseAllAndWaitAsync(TimeSpan.FromSeconds(20));
            swap.Swap();
            swapped = true;
            updateText.Text = $"Starting OSB Manager {offer.Version}...";
            var arguments = UpdateRelaunch.ArgumentsForRestart(Environment.GetCommandLineArgs().Skip(1));
            if (!await UpdateRelaunch.StartAsync(swap.ExePath, arguments, UpdateRelaunch.StartTimeout))
            {
                swap.RollBack();
                swapped = false;
                throw new UpdateException("The new version did not start, so the previous version was put back.");
            }
            services.Log.Info($"Updated to {offer.Version}; the new version is starting.");
            exitingForUpdate = true;
            Close();
        }
        catch (Exception e) when (e is UpdateException or IOException or UnauthorizedAccessException or OperationCanceledException or InvalidDataException)
        {
            if (swapped)
            {
                TryRollBack(swap);
            }
            services.Log.Error("The update failed", e);
            Note("error", TrailCodes.UpdateFailed);
            updateNotice.InstallFailed();
            ShowUpdateNotice(offer);
            OfferReleasePage($"The update to {offer.Version} failed: {e.Message}");
        }
        finally
        {
            TryDeleteDirectory(folder);
        }
    }

    private async Task CloseAllAndWaitAsync(TimeSpan timeout)
    {
        CloseAll(prompt: false);
        var deadline = DateTime.UtcNow + timeout;
        while (windows.Count > 0 && DateTime.UtcNow < deadline)
        {
            await Task.Delay(100);
        }
        if (windows.Count > 0)
        {
            throw new UpdateException($"{windows.Count} game window(s) did not close. Nothing was changed.");
        }
    }

    private void TryRollBack(ExeSwap swap)
    {
        try
        {
            swap.RollBack();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            services.Log.Error($"Could not put the previous version back. Rename {swap.PreviousPath} to {swap.ExePath} by hand", e);
        }
    }

    private void OfferReleasePage(string message)
    {
        if (MessageBox.Show(this, message + Environment.NewLine + Environment.NewLine + "Open the release page to download it by hand?",
                "Update", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes)
        {
            OpenUrl(updateNotice.Current?.ReleasePage ?? UpdateSource.LatestReleasePage);
        }
    }

    private static void OpenUrl(Uri url) => Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true });

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    private void BuildBotNotice()
    {
        var text = new Label
        {
            AutoSize = true,
            MaximumSize = new Size(760, 0),
            Text = "OSB replaces the previous bot. Replace with OSB installs OSB from its address and turns the previous bot's script off. " +
                "That script stays installed, so you can turn it on again. Keep leaves everything as it is and hides this notice for good.",
        };
        var buttons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Bottom };
        buttons.Controls.AddRange([ButtonFor("Replace with OSB", ReplaceNixxaneWithOsb), ButtonFor("Keep", KeepNixxane)]);
        var layout = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, Dock = DockStyle.Fill, WrapContents = false };
        layout.Controls.AddRange([text, buttons]);
        botNotice.Controls.Add(layout);
        botNotice.BackColor = SystemColors.Info;
    }

    private void RefreshBotNotice()
    {
        botNotice.Visible = BotScripts.ShouldOfferReplacement(services.Scripts.Scripts, services.Settings.BotNotice);
        var both = BotScripts.BothEnabled(services.Scripts.Scripts);
        botWarning.Visible = both;
        botWarning.Text = "OSB and the previous bot are both turned on. Two bots must not run together: turn one of them off.";
        if (both && !botWarningLogged)
        {
            services.Log.Warn("OSB and the previous bot are both turned on. Two bots must not run together.");
        }
        botWarningLogged = both;
    }

    private void KeepNixxane()
    {
        BotScripts.KeepNixxane(services.Settings);
        services.Log.Info("Kept the previous bot. The notice about OSB will not show again.");
        RefreshBotNotice();
    }

    private async void ReplaceNixxaneWithOsb()
    {
        var url = options.OsbUrl ?? BotScripts.OsbUrl;
        var job = scriptJobs.Begin();
        try
        {
            var osb = await BotScripts.ReplaceWithOsbAsync(services.Scripts, services.Http, services.Settings, url, allowLoopbackHttp: options.OsbUrl is not null);
            services.Log.Info($"Installed {osb.Meta.Name} {osb.Meta.Version} and turned the previous bot off. Reload the game windows to apply it.");
        }
        catch (Exception e)
        {
            services.Log.Error($"Could not install OSB from {url}", e);
            MessageBox.Show(this, $"Could not install OSB: {e.Message}\n\nThe previous bot was not changed.", "Replace with OSB", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            job.Dispose();
        }
        RefreshBotNotice();
    }

    private async Task InstallOsbThenWatchForUpdatesAsync()
    {
        var job = scriptJobs.Begin();
        try
        {
            await InstallOsbOnFirstStartAsync();
        }
        finally
        {
            job.Dispose();
        }
        if (closing || IsDisposed)
        {
            return;
        }
        osbUpdateTimer.Interval = options.OsbUrl is null ? (int)OsbUpdateFirstDelay.TotalMilliseconds : 3000;
        osbUpdateTimer.Tick += async (_, _) => await CheckOsbUpdateAsync();
        osbUpdateTimer.Start();
    }

    private async Task CheckOsbUpdateAsync()
    {
        osbUpdateTimer.Interval = options.OsbUrl is null ? (int)OsbUpdateInterval.TotalMilliseconds : 15000;
        if (closing || IsDisposed)
        {
            return;
        }
        var result = await osbUpdate.CheckAsync();
        if (closing || IsDisposed)
        {
            return;
        }
        switch (result.Outcome)
        {
            case OsbUpdateOutcome.Busy:
                osbUpdateTimer.Interval = (int)OsbUpdateBusyRetry.TotalMilliseconds;
                break;
            case OsbUpdateOutcome.Updated:
                services.Log.Info($"Updated OSB from {result.OldVersion} to {result.NewVersion}. Reload the game windows to apply it.");
                break;
            case OsbUpdateOutcome.Failed when result.FirstFailureInStreak:
                services.Log.Warn($"Could not check for an OSB update ({result.Error!.Message}). It will try again later.");
                Note("warn", TrailCodes.ScriptUpdateFailed);
                break;
        }
    }

    private async Task InstallOsbOnFirstStartAsync()
    {
        if (services.Settings.OsbFirstInstall != OsbFirstInstallState.Pending)
        {
            return;
        }
        var url = options.OsbUrl ?? BotScripts.OsbUrl;
        osbInstallLine.Text = "Installing OSB…";
        osbInstallLine.Visible = true;
        FirstInstallResult result;
        try
        {
            result = await OsbFirstInstall.RunAsync(services.Scripts, services.Http, services.Settings, url, allowLoopbackHttp: options.OsbUrl is not null);
        }
        catch (Exception e) when (e is OperationCanceledException or ObjectDisposedException or IOException)
        {
            result = new FirstInstallResult(FirstInstallOutcome.Failed, Error: e);
        }
        if (closing || IsDisposed)
        {
            return;
        }
        switch (result.Outcome)
        {
            case FirstInstallOutcome.Installed:
                var reload = windows.Count > 0 ? " Reload the game windows to apply it." : "";
                services.Log.Info($"Installed OSB {result.Script!.Meta.Version}. You can turn it off or remove it on the Scripts tab.{reload}");
                osbInstallLine.Visible = false;
                break;
            case FirstInstallOutcome.Failed:
                services.Log.Warn($"Could not install OSB on the first start ({result.Error!.Message}). It will try again at the next start.");
                osbInstallLine.Text = "Could not install OSB. It will try again at the next start, or add it with Add from URL.";
                break;
            default:
                osbInstallLine.Visible = false;
                break;
        }
    }

    private void OnScriptsChanged()
    {
        if (InvokeRequired)
        {
            BeginInvoke(RefreshScripts);
        }
        else
        {
            RefreshScripts();
        }
    }

    private void OnLogAdded(LogEntry entry)
    {
        if (IsDisposed || !IsHandleCreated)
        {
            return;
        }
        BeginInvoke(() =>
        {
            logList.Items.Add(entry.ToString());
            while (logList.Items.Count > 1000)
            {
                logList.Items.RemoveAt(0);
            }
            logList.TopIndex = logList.Items.Count - 1;
        });
    }

    private static TabPage Page(string title, Control content)
    {
        var page = new TabPage(title);
        page.Controls.Add(content);
        return page;
    }

    private Button ButtonFor(string text, Action action, int width = 0, string? tip = null)
    {
        var button = new Button { Text = text, AutoSize = width == 0, Margin = new Padding(3), AccessibleName = tip ?? text };
        if (width > 0)
        {
            button.Width = width;
        }
        if (tip is not null)
        {
            toolTip.SetToolTip(button, tip);
        }
        button.Click += (_, _) => action();
        return button;
    }
}
