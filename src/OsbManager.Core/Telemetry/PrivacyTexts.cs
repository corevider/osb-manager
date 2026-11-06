using System.Globalization;

namespace OsbManager.Core.Telemetry;

/// <summary>The texts of the privacy and report dialogs. Consent texts are those of CONSENT.md, version id <see cref="TextVersion"/>.</summary>
public sealed record PrivacyTexts
{
    public const string TextVersion = TelemetryLimits.ConsentTextId;
    private const string EnglishPolicyUrl = "https://osb.lol/en/privacy/";
    private const string TurkishPolicyUrl = "https://osb.lol/gizlilik/";
    public const string PrivacyEmail = "privacy@osb.lol";

    public required string PolicyUrl { get; init; }
    public string? KvkkNoticeUrl { get; init; }
    public string? KvkkNoticeLink { get; init; }
    public string? KvkkConsentUrl { get; init; }
    public string? KvkkConsentLink { get; init; }
    public required string PrivacyMenu { get; init; }
    public required string PrivacyTitle { get; init; }
    public required string UsageLabel { get; init; }
    public required string UsageHelp { get; init; }
    public required string CharactersLabel { get; init; }
    public required string CharactersHelp { get; init; }
    public required string ShowSent { get; init; }
    public required string NothingToShow { get; init; }
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
    public required string FirstRunText { get; init; }
    public required string FirstRunShare { get; init; }
    public required string FirstRunDecline { get; init; }
    public required string FirstRunWhat { get; init; }

    public static PrivacyTexts For(CultureInfo culture) =>
        string.Equals(culture.TwoLetterISOLanguageName, "tr", StringComparison.OrdinalIgnoreCase) ? Turkish : English;

    public static PrivacyTexts English { get; } = new()
    {
        PolicyUrl = EnglishPolicyUrl,
        PrivacyMenu = "Privacy…",
        PrivacyTitle = "Privacy",
        UsageLabel = "Share usage statistics",
        UsageHelp = "When this is on, OSB Manager sends a short status report about every 10 minutes to our server, api.osb.lol: the app and bot version, operating system, language, and for each game account the bot state, level, gold, HP and MP percentage, scroll counts and the current session's kills, deaths, XP, gold and SoX drops. It is linked to a random install ID, not to your login ID, password or computer. We use it to see how OSB is used and where it gets stuck, and keep it for 45 days (the install record for 90 days after it was last seen). Turn it off at any time; your data on our server is then deleted. Details: osb.lol/privacy",
        CharactersLabel = "Show my characters in the OSB dashboard",
        CharactersHelp = "Also sends your character names and server names, so the OSB team can see your characters by name in its private dashboard. Never shown publicly. Turning this off deletes the names at once.",
        StopConfirm = "Stop sharing and delete your usage data from api.osb.lol? Reports you already sent are deleted too.",
        ShowSent = "Show what is sent",
        NothingToShow = "Nothing would be sent right now: no game window is open.",
        DeleteData = "Delete my data",
        DeleteConfirm = "Delete all data for this install from api.osb.lol, including reports linked to it? This cannot be undone.",
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
        ReportNotice = "When you press Send, this report goes to the OSB team at our server, api.osb.lol: your description, the technical details shown below and the screenshot, if you added one. Please leave out passwords and personal details. If the report shows a bug, we may quote your description and parts of the details in a public GitHub issue; never your install ID, character names, e-mail or screenshot. Kept for 6 months after the matter closes.",
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
        FirstRunText = "If you choose Share, OSB Manager sends a short status report about every 10 minutes to our server, api.osb.lol: the app version, operating system and language, and for each game account the bot state, level, gold, HP and MP, scroll counts and the current session's kills, deaths, XP, gold and SoX drops. It is linked to a random install ID, not to your login ID, password or computer. We use it to see how OSB is used and where it gets stuck. If you choose No thanks, nothing is sent. You can switch it off at any time under Privacy, and your data on our server is then deleted.",
        FirstRunTitle = "Share usage statistics with the OSB team?",
        FirstRunShare = "Share",
        FirstRunDecline = "No thanks",
        FirstRunWhat = "What is sent?",
    };

    public static PrivacyTexts Turkish { get; } = new()
    {
        PolicyUrl = TurkishPolicyUrl,
        KvkkNoticeUrl = "https://osb.lol/kvkk/aydinlatma-metni/",
        KvkkNoticeLink = "KVKK aydınlatma metni",
        KvkkConsentUrl = "https://osb.lol/kvkk/acik-riza-metni/",
        KvkkConsentLink = "Açık rıza metni",
        PrivacyMenu = "Gizlilik…",
        PrivacyTitle = "Gizlilik",
        UsageLabel = "Kullanım istatistiklerini paylaş",
        UsageHelp = "Bu seçenek açıkken OSB Manager yaklaşık 10 dakikada bir sunucumuz api.osb.lol'a kısa bir durum raporu gönderir: uygulama ve bot sürümü, işletim sistemi, dil ve her oyun hesabı için bot durumu, seviye, altın, HP ve MP yüzdesi, scroll sayıları ile o anki oturumun öldürme, ölüm, XP, altın ve SoX düşüş sayıları. Bu veriler giriş kimliğine, şifrene ya da bilgisayarına değil, rastgele bir kurulum kimliğine bağlıdır. OSB'nin nasıl kullanıldığını ve nerede takıldığını görmek için kullanırız; 45 gün saklarız (kurulum kaydını son görülmeden 90 gün). İstediğin zaman kapatabilirsin; o zaman sunucudaki verilerin silinir. Ayrıntılar: osb.lol/gizlilik · Açık rıza metni: osb.lol/kvkk/acik-riza-metni",
        CharactersLabel = "Karakterlerimi OSB panelinde göster",
        CharactersHelp = "Karakter adlarını ve sunucu adlarını da gönderir; böylece OSB ekibi karakterlerini kendi özel panelinde adıyla görür. Hiçbir zaman herkese açık gösterilmez. Kapattığında adlar hemen silinir.",
        StopConfirm = "Paylaşım durdurulsun ve kullanım verilerin api.osb.lol'dan silinsin mi? Daha önce gönderdiğin raporlar da silinir.",
        ShowSent = "Gönderilenleri göster",
        NothingToShow = "Şu anda gönderilecek bir şey yok: açık oyun penceresi yok.",
        DeleteData = "Verilerimi sil",
        DeleteConfirm = "Bu kuruluma ait tüm veriler, bağlı raporlar dahil, api.osb.lol'dan silinsin mi? Bu işlem geri alınamaz.",
        DeleteFailed = "Sunucuya ulaşılamadı. Bu bilgisayardan artık hiçbir şey gönderilmiyor. Verilerin silinmesi için bu kurulum kimliğiyle {0} adresine e-posta gönderin: {1}",
        DownloadData = "Verilerimi indir",
        DownloadFailed = "Veriler indirilemedi. Daha sonra tekrar deneyin.",
        Saved = "{0} dosyasına kaydedildi.",
        InstallId = "Kurulum kimliği",
        ConsentRecord = "Kayıtlı onay: metin sürümü {0}, {1}",
        NoConsentRecord = "Kayıtlı onay yok. Hiçbir şey gönderilmez.",
        LastSent = "Son gönderim",
        NotSentYet = "henüz gönderilmedi",
        ServerUnreachable = "sunucuya ulaşılamıyor",
        ServerMessage = "Sunucudan mesaj",
        PolicyLine = "Gizlilik politikası: " + TurkishPolicyUrl,
        PolicyLink = "Gizlilik politikası",
        Copy = "Kopyala",
        Close = "Kapat",
        ReportMenu = "Sorun bildir…",
        ReportTitle = "Sorun bildir",
        ReportNotice = "Gönder'e bastığında bu rapor sunucumuz api.osb.lol'daki OSB ekibine gider: açıklaman, aşağıda gösterilen teknik ayrıntılar ve eklediysen ekran görüntüsü. Şifre ve kişisel bilgi yazma. Rapor bir hatayı gösteriyorsa açıklamandan ve ayrıntılardan herkese açık bir GitHub konusunda alıntı yapabiliriz; kurulum kimliğini, karakter adlarını, e-postanı ya da ekran görüntüsünü asla. Konu kapandıktan sonra 6 ay saklanır.",
        ReportNoticeAnonymous = "Kullanım istatistikleri kapalı, bu yüzden rapor anonim. Daha sonra silinmesini istersen rapor kodunu sakla.",
        Kind = "Tür",
        KindBug = "Hata",
        KindFeature = "Özellik isteği",
        Description = "Açıklama (en fazla 2000 karakter)",
        Screenshot = "Ekran görüntüsü",
        AddScreenshot = "Ekran görüntüsü ekle",
        ScreenshotNotice = "OSB Manager seçtiğin oyun penceresinin tek bir görüntüsünü alır ve bir şey gönderilmeden önce burada gösterir. Görüntü yalnızca bu raporla, yalnızca Gönder'e bastığında gönderilir ve 30 gün saklanır. Paylaşmak istemediğin ad ya da sohbet var mı diye bak; Kaldır ile çıkarabilirsin.",
        ChooseWindow = "Hangi oyun penceresi?",
        RemoveScreenshot = "Kaldır",
        ScreenshotFailed = "Ekran görüntüsü alınamadı.",
        Preview = "Gönderilecek içeriğin tamamı",
        NoteAnonymous = "Kullanım istatistikleri kapalı: bu rapor bir kuruluma bağlı değil.",
        NoteLinked = "Kullanım istatistikleri açık: bu rapor kurulum kimliğine bağlanır.",
        Send = "Gönder",
        Cancel = "İptal",
        ConfirmSend = "Bu rapor şimdi OSB ekibine gönderilsin mi?",
        SentWithCode = "Gönderildi. Rapor kodun {0}. Raporun daha sonra silinmesini istersen bu kodu sakla.",
        SentWithoutCode = "Gönderildi.",
        Queued = "Sunucuya ulaşılamadı. Rapor kaydedildi ve daha sonra gönderilecek ({0}).",
        QueueFull = "Rapor gönderilemedi ve bekleyen çok fazla rapor var. Daha sonra tekrar deneyin.",
        TooLarge = "Rapor sonradan göndermek üzere kaydedilemeyecek kadar büyük. Ekran görüntüsünü kaldırıp tekrar deneyin.",
        NotSaved = "Rapor gönderilemedi ve kaydedilemedi de ({0}). Daha sonra tekrar deneyin.",
        Rejected = "Sunucu raporu kabul etmedi ({0}). Rapor gönderilmedi.",
        DescriptionNeeded = "Önce sorunu açıklayın.",
        UnsentMenu = "Gönderilmemiş raporlar…",
        UnsentTitle = "Gönderilmemiş raporlar",
        UnsentPending = "Gönderilmeyi bekliyor",
        UnsentFailed = "72 saatte gönderilemedi",
        SendAgain = "Tekrar gönder",
        Delete = "Sil",
        FirstRunText = "Paylaş'ı seçersen OSB Manager yaklaşık 10 dakikada bir sunucumuz api.osb.lol'a kısa bir durum raporu gönderir: uygulama sürümü, işletim sistemi ve dil, her oyun hesabı için bot durumu, seviye, altın, HP ve MP, scroll sayıları ve o anki oturumun öldürme, ölüm, XP, altın ve SoX düşüş sayıları. Bu veriler giriş kimliğine, şifrene ya da bilgisayarına değil, rastgele bir kurulum kimliğine bağlıdır. OSB'nin nasıl kullanıldığını ve nerede takıldığını görmek için kullanırız. \"Hayır, teşekkürler\" dersen hiçbir şey gönderilmez. İstediğin zaman Gizlilik bölümünden kapatabilirsin; o zaman sunucudaki verilerin silinir.",
        FirstRunTitle = "Kullanım istatistiklerini OSB ekibiyle paylaşmak ister misin?",
        FirstRunShare = "Paylaş",
        FirstRunDecline = "Hayır, teşekkürler",
        FirstRunWhat = "Neler gönderiliyor?",
    };
}
