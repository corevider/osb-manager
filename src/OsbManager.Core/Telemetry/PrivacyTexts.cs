namespace OsbManager.Core.Telemetry;

/// <summary>The texts of the privacy and report dialogs. Consent texts are those of CONSENT.md, version id <see cref="TextVersion"/>.</summary>
public sealed record PrivacyTexts
{
    public const string TextVersion = TelemetryLimits.ConsentTextId;
    private const string EnglishPolicyUrl = "https://osb.lol/en/privacy/";
    private const string KvkkNoticeAddress = "https://osb.lol/kvkk/aydinlatma-metni/";
    private const string KvkkConsentAddress = "https://osb.lol/kvkk/acik-riza-metni/";
    public const string PrivacyEmail = "privacy@osb.lol";

    public required string PolicyUrl { get; init; }
    public required string KvkkNoticeUrl { get; init; }
    public required string KvkkNoticeLink { get; init; }
    public required string KvkkConsentUrl { get; init; }
    public required string KvkkConsentLink { get; init; }
    public required string PrivacyMenu { get; init; }
    public required string PrivacyTitle { get; init; }
    public required string UsageLabel { get; init; }
    public required string UsageHelp { get; init; }
    public required string CharactersLabel { get; init; }
    public required string CharactersHelp { get; init; }
    public required string ShowSent { get; init; }
    public required string NothingToShow { get; init; }
    public required string SentUsageTitle { get; init; }
    public required string SentDiagnosticsTitle { get; init; }
    public required string StopConfirm { get; init; }
    public required string DeleteData { get; init; }
    public required string DeleteConfirm { get; init; }
    public required string DeleteFailed { get; init; }
    public required string DownloadData { get; init; }
    public required string DownloadFailed { get; init; }
    public required string Saved { get; init; }
    public required string InstallId { get; init; }
    public required string ConsentRecord { get; init; }
    public required string NoConsentRecord { get; init; }
    public required string LastSent { get; init; }
    public required string NotSentYet { get; init; }
    public required string ServerUnreachable { get; init; }
    public required string ServerMessage { get; init; }
    public required string PolicyLine { get; init; }
    public required string PolicyLink { get; init; }
    public required string Copy { get; init; }
    public required string Close { get; init; }
    public required string ReportMenu { get; init; }
    public required string ReportTitle { get; init; }
    public required string ReportNotice { get; init; }
    public required string ReportNoticeAnonymous { get; init; }
    public required string Kind { get; init; }
    public required string KindBug { get; init; }
    public required string KindFeature { get; init; }
    public required string Description { get; init; }
    public required string Screenshot { get; init; }
    public required string AddScreenshot { get; init; }
    public required string ScreenshotNotice { get; init; }
    public required string ChooseWindow { get; init; }
    public required string RemoveScreenshot { get; init; }
    public required string ScreenshotFailed { get; init; }
    public required string Preview { get; init; }
    public required string NoteAnonymous { get; init; }
    public required string NoteLinked { get; init; }
    public required string Send { get; init; }
    public required string Cancel { get; init; }
    public required string ConfirmSend { get; init; }
    public required string SentWithCode { get; init; }
    public required string SentWithoutCode { get; init; }
    public required string Queued { get; init; }
    public required string QueueFull { get; init; }
    public required string TooLarge { get; init; }
    public required string NotSaved { get; init; }
    public required string Rejected { get; init; }
    public required string DescriptionNeeded { get; init; }
    public required string UnsentMenu { get; init; }
    public required string UnsentTitle { get; init; }
    public required string UnsentPending { get; init; }
    public required string UnsentFailed { get; init; }
    public required string SendAgain { get; init; }
    public required string Delete { get; init; }
    public required string FirstRunTitle { get; init; }
    public required string FirstRunChangedLead { get; init; }
    public required string FirstRunText { get; init; }
    public required string FirstRunShare { get; init; }
    public required string FirstRunDecline { get; init; }
    public required string FirstRunWhat { get; init; }
    public required string FirstRunClose { get; init; }

    public static PrivacyTexts English { get; } = new()
    {
        PolicyUrl = EnglishPolicyUrl,
        KvkkNoticeUrl = KvkkNoticeAddress,
        KvkkNoticeLink = "KVKK notice (Turkish)",
        KvkkConsentUrl = KvkkConsentAddress,
        KvkkConsentLink = "KVKK explicit consent (Turkish)",
        PrivacyMenu = "Privacy…",
        PrivacyTitle = "Privacy",
        UsageLabel = "Share usage statistics, error reports and performance data",
        UsageHelp = "When this is on, OSB Manager sends data to our server, api.osb.lol, about every 10 minutes, so we can see how OSB is used and find and fix its errors:\r\n"
            + "- Usage: the app and bot version, operating system and language, and for each game account the bot state, level, gold, HP and MP percentage, scroll counts and the current session's kills, deaths, XP, gold and SoX drops.\r\n"
            + "- Errors: which part of the app failed and how (the error type, a fixed message and the place in our code), what the app did just before (fixed event codes, never the text of your log), crashes and freezes of game windows, and how the app last closed.\r\n"
            + "- Performance: the memory and processor use of the app and its game windows, the Windows and WebView2 versions, and the rough size of your computer (memory, processor cores, graphics card maker).\r\n"
            + "\r\n"
            + "Unless you also turn on character names below, it contains no character, player or account names. It never contains chat, positions, passwords, login IDs, file paths, your computer's name, hardware IDs or memory dumps. It is kept under a random install ID that is not linked to your name, login ID or computer. We keep usage data for 45 days, error data for 30 days and performance data for 14 days, and the install record for 90 days after it was last seen. Daily totals without the install ID are kept for 13 months. Turn it off at any time; your data on our server is then deleted, except those daily totals, which cannot identify you. Details: osb.lol/privacy",
        CharactersLabel = "Show my characters in the OSB dashboard",
        CharactersHelp = "Also sends your character names and server names, so the OSB team can see your characters by name in its private dashboard. Never shown publicly. Turning this off deletes the names at once.",
        StopConfirm = "Stop sharing usage statistics, error reports and performance data, and delete them from api.osb.lol? Reports you already sent are deleted too.",
        ShowSent = "Show what is sent",
        NothingToShow = "Nothing would be sent right now: no game window is open.",
        SentUsageTitle = "Usage statistics, next batch",
        SentDiagnosticsTitle = "Error reports and performance data, next batch",
        DeleteData = "Delete my data",
        DeleteConfirm = "Delete all data for this install from api.osb.lol, including linked reports, error reports and performance data? Sharing is turned off. This cannot be undone.",
        DeleteFailed = "The server could not be reached. Nothing is sent from this PC any more. To have the data deleted, e-mail {0} with this install ID: {1}",
        DownloadData = "Download my data",
        DownloadFailed = "The data could not be downloaded. Try again later.",
        Saved = "Saved to {0}.",
        InstallId = "Install ID",
        ConsentRecord = "Consent recorded: text version {0}, {1}",
        NoConsentRecord = "No consent recorded. Nothing is sent.",
        LastSent = "Last sent",
        NotSentYet = "not sent yet",
        ServerUnreachable = "server unreachable",
        ServerMessage = "Message from the server",
        PolicyLine = "Privacy policy: " + EnglishPolicyUrl,
        PolicyLink = "Privacy policy",
        Copy = "Copy",
        Close = "Close",
        ReportMenu = "Report a problem…",
        ReportTitle = "Report a problem",
        ReportNotice = "When you press Send, this report goes to the OSB team at our server, api.osb.lol: your description, the technical details shown below and the screenshot, if you added one. Please leave out passwords and personal details. We never copy your description or the details into a public GitHub issue. If the report shows a bug, we may open a public issue that we write ourselves, with only our own summary, the product and version and the report code. It never contains your install ID, character names, e-mail or screenshot. Kept for 6 months after the matter closes.",
        ReportNoticeAnonymous = "Usage statistics are off, so this report is anonymous. Keep the report code if you want it deleted later.",
        Kind = "Kind",
        KindBug = "Bug",
        KindFeature = "Feature request",
        Description = "Description (up to 2000 characters)",
        Screenshot = "Screenshot",
        AddScreenshot = "Add screenshot",
        ScreenshotNotice = "OSB Manager takes one picture of the game window you choose and shows it here before anything is sent. It is sent only with this report, only when you press Send, and kept for 30 days. Check it for names or chat you do not want to share; Remove takes it out.",
        ChooseWindow = "Which game window?",
        RemoveScreenshot = "Remove",
        ScreenshotFailed = "The screenshot could not be taken.",
        Preview = "Exactly what is sent",
        NoteAnonymous = "Usage statistics are off: this report is not linked to an install.",
        NoteLinked = "Usage statistics are on: this report is linked to your install ID.",
        Send = "Send",
        Cancel = "Cancel",
        ConfirmSend = "Send this report to the OSB team now?",
        SentWithCode = "Sent. Your report code is {0}. Keep it if you want the report deleted later.",
        SentWithoutCode = "Sent.",
        Queued = "The server could not be reached. The report is saved and will be sent later ({0}).",
        QueueFull = "The report was not sent and too many reports are waiting. Try again later.",
        TooLarge = "The report is too large to save for later. Remove the screenshot and try again.",
        NotSaved = "The report could not be sent and could not be saved either ({0}). Try again later.",
        Rejected = "The server did not accept the report ({0}). It was not sent.",
        DescriptionNeeded = "Describe the problem first.",
        UnsentMenu = "Unsent reports…",
        UnsentTitle = "Unsent reports",
        UnsentPending = "Waiting to be sent",
        UnsentFailed = "Could not be sent in 72 hours",
        SendAgain = "Send again",
        Delete = "Delete",
        FirstRunTitle = "Share usage statistics, error reports and performance data with the OSB team?",
        FirstRunChangedLead = "What OSB Manager shares has changed: it now includes error reports and performance data.",
        FirstRunText = "If you choose Share, OSB Manager sends a short report about every 10 minutes to our server, api.osb.lol: the app version, operating system and language; for each game account the bot state, level, gold, HP and MP, scroll counts and the current session's kills, deaths, XP, gold and SoX drops; and error reports, crash reports and memory and processor use. It contains no character or account names, chat, passwords, login IDs, file paths or memory dumps, and it is kept under a random install ID that is not linked to you. We use it to see how OSB is used and to find and fix problems. If you choose No thanks, nothing is sent. You can switch it off at any time under Privacy, and your data on our server is then deleted.",
        FirstRunShare = "Share",
        FirstRunDecline = "No thanks",
        FirstRunWhat = "What is sent?",
        FirstRunClose = "Close (No thanks)",
    };
}
