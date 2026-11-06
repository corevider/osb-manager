import Foundation

public enum ConsentLanguage: String, Sendable {
    case english = "en"
    case turkish = "tr"

    public static func preferred(_ languages: [String] = Locale.preferredLanguages) -> ConsentLanguage {
        guard let first = languages.first?.lowercased() else { return .english }
        return first == "tr" || first.hasPrefix("tr-") || first.hasPrefix("tr_") ? .turkish : .english
    }

    public var code: String { rawValue }
}

public struct ConsentTexts: Sendable {
    public let language: ConsentLanguage
    public let firstRunTitle: String
    public let firstRunBody: String
    public let share: String
    public let noThanks: String
    public let whatIsSent: String
    public let privacyPolicy: String
    public let privacyPolicyUrl: URL
    public let kvkkNotice: String?
    public let kvkkNoticeUrl: URL?
    public let explicitConsent: String?
    public let explicitConsentUrl: URL?
    public let usageLabel: String
    public let usageHelp: String
    public let stopSharingQuestion: String
    public let charactersLabel: String
    public let charactersHelp: String
    public let deleteQuestion: String
    public let reportConfirmation: String
    public let reportAnonymousNote: String
    public let screenshotButton: String
    public let screenshotText: String
    public let screenshotRemove: String
    private let reportSentTemplate: String

    public func reportSent(code: String) -> String {
        reportSentTemplate.replacingOccurrences(of: "R-XXXXXXXX", with: code)
    }

    public static func texts(for language: ConsentLanguage) -> ConsentTexts {
        language == .turkish ? turkish : english
    }

    private static func link(_ address: String) -> URL {
        URL(string: address) ?? URL(fileURLWithPath: "/")
    }

    public static let english = ConsentTexts(
        language: .english,
        firstRunTitle: "Share usage statistics with the OSB team?",
        firstRunBody: "If you choose Share, OSB Manager sends a short status report about every 10 minutes to our server, api.osb.lol: the app version, operating system and language, and for each game account the bot state, level, gold, HP and MP, scroll counts and the current session's kills, deaths, XP, gold and SoX drops. It is linked to a random install ID, not to your login ID, password or computer. We use it to see how OSB is used and where it gets stuck. If you choose No thanks, nothing is sent. You can switch it off at any time under Privacy, and your data on our server is then deleted.",
        share: "Share",
        noThanks: "No thanks",
        whatIsSent: "What is sent?",
        privacyPolicy: "Privacy policy",
        privacyPolicyUrl: link("https://osb.lol/en/privacy/"),
        kvkkNotice: nil,
        kvkkNoticeUrl: nil,
        explicitConsent: nil,
        explicitConsentUrl: nil,
        usageLabel: "Share usage statistics",
        usageHelp: "When this is on, OSB Manager sends a short status report about every 10 minutes to our server, api.osb.lol: the app and bot version, operating system, language, and for each game account the bot state, level, gold, HP and MP percentage, scroll counts and the current session's kills, deaths, XP, gold and SoX drops. It is linked to a random install ID, not to your login ID, password or computer. We use it to see how OSB is used and where it gets stuck, and keep it for 45 days (the install record for 90 days after it was last seen). Turn it off at any time; your data on our server is then deleted. Details: osb.lol/privacy",
        stopSharingQuestion: "Stop sharing and delete your usage data from api.osb.lol? Reports you already sent are deleted too.",
        charactersLabel: "Show my characters in the OSB dashboard",
        charactersHelp: "Also sends your character names and server names, so the OSB team can see your characters by name in its private dashboard. Never shown publicly. Turning this off deletes the names at once.",
        deleteQuestion: "Delete all data for this install from api.osb.lol, including reports linked to it? This cannot be undone.",
        reportConfirmation: "When you press Send, this report goes to the OSB team at our server, api.osb.lol: your description, the technical details shown below and the screenshot, if you added one. Please leave out passwords and personal details. If the report shows a bug, we may quote your description and parts of the details in a public GitHub issue; never your install ID, character names, e-mail or screenshot. Kept for 6 months after the matter closes.",
        reportAnonymousNote: "Usage statistics are off, so this report is anonymous. Keep the report code if you want it deleted later.",
        screenshotButton: "Add screenshot",
        screenshotText: "OSB Manager takes one picture of the game window you choose and shows it here before anything is sent. It is sent only with this report, only when you press Send, and kept for 30 days. Check it for names or chat you do not want to share; Remove takes it out.",
        screenshotRemove: "Remove",
        reportSentTemplate: "Sent. Your report code is R-XXXXXXXX. Keep it if you want the report deleted later."
    )

    public static let turkish = ConsentTexts(
        language: .turkish,
        firstRunTitle: "Kullanım istatistiklerini OSB ekibiyle paylaşmak ister misin?",
        firstRunBody: "Paylaş'ı seçersen OSB Manager yaklaşık 10 dakikada bir sunucumuz api.osb.lol'a kısa bir durum raporu gönderir: uygulama sürümü, işletim sistemi ve dil, her oyun hesabı için bot durumu, seviye, altın, HP ve MP, scroll sayıları ve o anki oturumun öldürme, ölüm, XP, altın ve SoX düşüş sayıları. Bu veriler giriş kimliğine, şifrene ya da bilgisayarına değil, rastgele bir kurulum kimliğine bağlıdır. OSB'nin nasıl kullanıldığını ve nerede takıldığını görmek için kullanırız. \"Hayır, teşekkürler\" dersen hiçbir şey gönderilmez. İstediğin zaman Gizlilik bölümünden kapatabilirsin; o zaman sunucudaki verilerin silinir.",
        share: "Paylaş",
        noThanks: "Hayır, teşekkürler",
        whatIsSent: "Neler gönderiliyor?",
        privacyPolicy: "Gizlilik politikası",
        privacyPolicyUrl: link("https://osb.lol/gizlilik/"),
        kvkkNotice: "KVKK aydınlatma metni",
        kvkkNoticeUrl: link("https://osb.lol/kvkk/aydinlatma-metni/"),
        explicitConsent: "Açık rıza metni",
        explicitConsentUrl: link("https://osb.lol/kvkk/acik-riza-metni/"),
        usageLabel: "Kullanım istatistiklerini paylaş",
        usageHelp: "Bu seçenek açıkken OSB Manager yaklaşık 10 dakikada bir sunucumuz api.osb.lol'a kısa bir durum raporu gönderir: uygulama ve bot sürümü, işletim sistemi, dil ve her oyun hesabı için bot durumu, seviye, altın, HP ve MP yüzdesi, scroll sayıları ile o anki oturumun öldürme, ölüm, XP, altın ve SoX düşüş sayıları. Bu veriler giriş kimliğine, şifrene ya da bilgisayarına değil, rastgele bir kurulum kimliğine bağlıdır. OSB'nin nasıl kullanıldığını ve nerede takıldığını görmek için kullanırız; 45 gün saklarız (kurulum kaydını son görülmeden 90 gün). İstediğin zaman kapatabilirsin; o zaman sunucudaki verilerin silinir. Ayrıntılar: osb.lol/gizlilik · Açık rıza metni: osb.lol/kvkk/acik-riza-metni",
        stopSharingQuestion: "Paylaşım durdurulsun ve kullanım verilerin api.osb.lol'dan silinsin mi? Daha önce gönderdiğin raporlar da silinir.",
        charactersLabel: "Karakterlerimi OSB panelinde göster",
        charactersHelp: "Karakter adlarını ve sunucu adlarını da gönderir; böylece OSB ekibi karakterlerini kendi özel panelinde adıyla görür. Hiçbir zaman herkese açık gösterilmez. Kapattığında adlar hemen silinir.",
        deleteQuestion: "Bu kuruluma ait tüm veriler, bağlı raporlar dahil, api.osb.lol'dan silinsin mi? Bu işlem geri alınamaz.",
        reportConfirmation: "Gönder'e bastığında bu rapor sunucumuz api.osb.lol'daki OSB ekibine gider: açıklaman, aşağıda gösterilen teknik ayrıntılar ve eklediysen ekran görüntüsü. Şifre ve kişisel bilgi yazma. Rapor bir hatayı gösteriyorsa açıklamandan ve ayrıntılardan herkese açık bir GitHub konusunda alıntı yapabiliriz; kurulum kimliğini, karakter adlarını, e-postanı ya da ekran görüntüsünü asla. Konu kapandıktan sonra 6 ay saklanır.",
        reportAnonymousNote: "Kullanım istatistikleri kapalı, bu yüzden rapor anonim. Daha sonra silinmesini istersen rapor kodunu sakla.",
        screenshotButton: "Ekran görüntüsü ekle",
        screenshotText: "OSB Manager seçtiğin oyun penceresinin tek bir görüntüsünü alır ve bir şey gönderilmeden önce burada gösterir. Görüntü yalnızca bu raporla, yalnızca Gönder'e bastığında gönderilir ve 30 gün saklanır. Paylaşmak istemediğin ad ya da sohbet var mı diye bak; Kaldır ile çıkarabilirsin.",
        screenshotRemove: "Kaldır",
        reportSentTemplate: "Gönderildi. Rapor kodun R-XXXXXXXX. Raporun daha sonra silinmesini istersen bu kodu sakla."
    )
}

public struct InterfaceTexts: Sendable {
    public let privacyTitle: String
    public let privacyMenu: String
    public let reportMenu: String
    public let showWhatIsSent: String
    public let nothingToShow: String
    public let nothingSentWhileOff: String
    public let deleteData: String
    public let downloadData: String
    public let installId: String
    public let copy: String
    public let lastSent: String
    public let notSentYet: String
    public let serverUnreachable: String
    public let serverMessage: String
    public let noInstallYet: String
    public let reportTitle: String
    public let kind: String
    public let bug: String
    public let feature: String
    public let description: String
    public let preview: String
    public let send: String
    public let cancel: String
    public let close: String
    public let sending: String
    public let queued: String
    public let notSent: String
    public let rejected: String
    public let queueFull: String
    public let chooseWindow: String
    public let noGameWindow: String
    public let screenshotFailed: String
    public let deletionFailed: String
    public let deleted: String
    public let exportFailed: String
    public let exportSaved: String
    public let deleteButton: String
    public let stopButton: String
    public let keep: String
    public let unsentReports: String
    public let noUnsentReports: String
    public let sendAgain: String

    public static func texts(for language: ConsentLanguage) -> InterfaceTexts {
        language == .turkish ? turkish : english
    }

    public static let english = InterfaceTexts(
        privacyTitle: "Privacy",
        privacyMenu: "Privacy…",
        reportMenu: "Report a problem…",
        showWhatIsSent: "Show what is sent",
        nothingToShow: "Nothing to send yet: no game window has reported a status.",
        nothingSentWhileOff: "Usage statistics are off. Nothing is sent.",
        deleteData: "Delete my data…",
        downloadData: "Download my data…",
        installId: "Install ID",
        copy: "Copy",
        lastSent: "Last sent",
        notSentYet: "not sent yet",
        serverUnreachable: "server unreachable",
        serverMessage: "Message from the server",
        noInstallYet: "none: usage statistics are off",
        reportTitle: "Report a problem",
        kind: "Kind",
        bug: "Bug",
        feature: "Feature request",
        description: "Description",
        preview: "Exactly what is sent",
        send: "Send",
        cancel: "Cancel",
        close: "Close",
        sending: "Sending…",
        queued: "Not delivered yet. The report is saved and sent again later.",
        notSent: "Not sent. Copy the text above and try again later.",
        rejected: "The server did not accept this report.",
        queueFull: "Five reports are already waiting to be sent. Try again later.",
        chooseWindow: "Game window",
        noGameWindow: "No game window is open.",
        screenshotFailed: "The screenshot could not be taken.",
        deletionFailed: "The server could not be reached. Your local install ID and key are deleted. To have the server data deleted, e-mail the install ID shown here.",
        deleted: "Your data was deleted.",
        exportFailed: "The data could not be downloaded.",
        exportSaved: "Your data was saved.",
        deleteButton: "Delete",
        stopButton: "Stop sharing",
        keep: "Keep sharing",
        unsentReports: "Reports that could not be sent",
        noUnsentReports: "There are no unsent reports.",
        sendAgain: "Send again"
    )

    public static let turkish = InterfaceTexts(
        privacyTitle: "Gizlilik",
        privacyMenu: "Gizlilik…",
        reportMenu: "Sorun bildir…",
        showWhatIsSent: "Neler gönderiliyor?",
        nothingToShow: "Henüz gönderilecek bir şey yok: hiçbir oyun penceresi durum bildirmedi.",
        nothingSentWhileOff: "Kullanım istatistikleri kapalı. Hiçbir şey gönderilmez.",
        deleteData: "Verilerimi sil…",
        downloadData: "Verilerimi indir…",
        installId: "Kurulum kimliği",
        copy: "Kopyala",
        lastSent: "Son gönderim",
        notSentYet: "henüz gönderilmedi",
        serverUnreachable: "sunucuya ulaşılamadı",
        serverMessage: "Sunucudan mesaj",
        noInstallYet: "yok: kullanım istatistikleri kapalı",
        reportTitle: "Sorun bildir",
        kind: "Tür",
        bug: "Hata",
        feature: "Özellik isteği",
        description: "Açıklama",
        preview: "Gönderilenin tam kendisi",
        send: "Gönder",
        cancel: "İptal",
        close: "Kapat",
        sending: "Gönderiliyor…",
        queued: "Henüz iletilemedi. Rapor kaydedildi ve daha sonra yeniden gönderilecek.",
        notSent: "Gönderilemedi. Yukarıdaki metni kopyala ve daha sonra tekrar dene.",
        rejected: "Sunucu bu raporu kabul etmedi.",
        queueFull: "Beş rapor zaten gönderilmeyi bekliyor. Daha sonra tekrar dene.",
        chooseWindow: "Oyun penceresi",
        noGameWindow: "Açık oyun penceresi yok.",
        screenshotFailed: "Ekran görüntüsü alınamadı.",
        deletionFailed: "Sunucuya ulaşılamadı. Yerel kurulum kimliğin ve anahtarın silindi. Sunucudaki verilerin silinmesi için burada gösterilen kurulum kimliğini e-postayla bildir.",
        deleted: "Verilerin silindi.",
        exportFailed: "Veriler indirilemedi.",
        exportSaved: "Verilerin kaydedildi.",
        deleteButton: "Sil",
        stopButton: "Paylaşımı durdur",
        keep: "Paylaşmaya devam et",
        unsentReports: "Gönderilemeyen raporlar",
        noUnsentReports: "Gönderilemeyen rapor yok.",
        sendAgain: "Yeniden gönder"
    )
}
