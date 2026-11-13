import Foundation

public enum InterfaceLocale {
    public static let fallback = "en"

    public static func code(_ languages: [String] = Locale.preferredLanguages) -> String {
        guard let first = languages.first else { return fallback }
        let primary = first.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? ""
        let letters = primary.unicodeScalars.allSatisfy { $0.value >= 97 && $0.value <= 122 }
        return letters && (2...3).contains(primary.count) ? primary : fallback
    }
}

public struct ConsentTexts: Sendable {
    public let firstRunTitle: String
    public let firstRunChangedLead: String
    public let firstRunBody: String
    public let share: String
    public let noThanks: String
    public let closeAsNoThanks: String
    public let whatIsSent: String
    public let privacyPolicy: String
    public let privacyPolicyUrl: URL
    public let kvkkNotice: String
    public let kvkkNoticeUrl: URL
    public let explicitConsent: String
    public let explicitConsentUrl: URL
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
    let reportSentTemplate: String

    public func reportSent(code: String) -> String {
        reportSentTemplate.replacingOccurrences(of: "R-XXXXXXXX", with: code)
    }

    private static func link(_ address: String) -> URL {
        URL(string: address) ?? URL(fileURLWithPath: "/")
    }

    public static let english = ConsentTexts(
        firstRunTitle: "Share usage statistics, error reports and performance data with the OSB team?",
        firstRunChangedLead: "What OSB Manager shares has changed: it now includes error reports and performance data.",
        firstRunBody: "If you choose Share, OSB Manager sends a short report about every 10 minutes to our server, api.osb.lol: the app version, operating system and language; for each game account the bot state, level, gold, HP and MP, scroll counts and the current session's kills, deaths, XP, gold and SoX drops; and error reports, crash reports and memory and processor use. It contains no character or account names, chat, passwords, login IDs, file paths or memory dumps, and it is kept under a random install ID that is not linked to you. We use it to see how OSB is used and to find and fix problems. If you choose No thanks, nothing is sent. You can switch it off at any time under Privacy, and your data on our server is then deleted.",
        share: "Share",
        noThanks: "No thanks",
        closeAsNoThanks: "Close (No thanks)",
        whatIsSent: "What is sent?",
        privacyPolicy: "Privacy policy",
        privacyPolicyUrl: link("https://osb.lol/en/privacy/"),
        kvkkNotice: "KVKK notice (Turkish)",
        kvkkNoticeUrl: link("https://osb.lol/kvkk/aydinlatma-metni/"),
        explicitConsent: "KVKK explicit consent (Turkish)",
        explicitConsentUrl: link("https://osb.lol/kvkk/acik-riza-metni/"),
        usageLabel: "Share usage statistics, error reports and performance data",
        usageHelp: "When this is on, OSB Manager sends data to our server, api.osb.lol, about every 10 minutes, so we can see how OSB is used and find and fix its errors:\n"
            + "- Usage: the app and bot version, operating system and language, and for each game account the bot state, level, gold, HP and MP percentage, scroll counts and the current session's kills, deaths, XP, gold and SoX drops.\n"
            + "- Errors: which part of the app failed and how (the error type, a fixed message and the place in our code), what the app did just before (fixed event codes, never the text of your log), crashes and freezes of game windows, and how the app last closed.\n"
            + "- Performance: the memory and processor use of the app and its game windows, the Windows and WebView2 versions, and the rough size of your computer (memory, processor cores, graphics card maker).\n"
            + "\n"
            + "Unless you also turn on character names below, it contains no character, player or account names. It never contains chat, positions, passwords, login IDs, file paths, your computer's name, hardware IDs or memory dumps. It is kept under a random install ID that is not linked to your name, login ID or computer. We keep usage data for 45 days, error data for 30 days and performance data for 14 days, and the install record for 90 days after it was last seen. Daily totals without the install ID are kept for 13 months. Turn it off at any time; your data on our server is then deleted, except those daily totals, which cannot identify you. Details: osb.lol/privacy",
        stopSharingQuestion: "Stop sharing usage statistics, error reports and performance data, and delete them from api.osb.lol? Reports you already sent are deleted too.",
        charactersLabel: "Show my characters in the OSB dashboard",
        charactersHelp: "Also sends your character names and server names, so the OSB team can see your characters by name in its private dashboard. Never shown publicly. Turning this off deletes the names at once.",
        deleteQuestion: "Delete all data for this install from api.osb.lol, including linked reports, error reports and performance data? Sharing is turned off. This cannot be undone.",
        reportConfirmation: "When you press Send, this report goes to the OSB team at our server, api.osb.lol: your description, the technical details shown below and the screenshot, if you added one. Please leave out passwords and personal details. We never copy your description or the details into a public GitHub issue. If the report shows a bug, we may open a public issue that we write ourselves, with only our own summary, the product and version and the report code. It never contains your install ID, character names, e-mail or screenshot. Kept for 6 months after the matter closes.",
        reportAnonymousNote: "Usage statistics are off, so this report is anonymous. Keep the report code if you want it deleted later.",
        screenshotButton: "Add screenshot",
        screenshotText: "OSB Manager takes one picture of the game window you choose and shows it here before anything is sent. It is sent only with this report, only when you press Send, and kept for 30 days. Check it for names or chat you do not want to share; Remove takes it out.",
        screenshotRemove: "Remove",
        reportSentTemplate: "Sent. Your report code is R-XXXXXXXX. Keep it if you want the report deleted later."
    )
}

public enum PreviewText {
    public static func compose(usage: String?, diagnostics: String?, texts: InterfaceTexts) -> String? {
        var sections: [String] = []
        if let usage { sections.append(texts.sentUsageTitle + "\n" + usage) }
        if let diagnostics { sections.append(texts.sentDiagnosticsTitle + "\n" + diagnostics) }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }
}

public struct InterfaceTexts: Sendable {
    public let privacyTitle: String
    public let privacyMenu: String
    public let reportMenu: String
    public let showWhatIsSent: String
    public let nothingToShow: String
    public let sentUsageTitle: String
    public let sentDiagnosticsTitle: String
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
    public let ok: String

    public static let english = InterfaceTexts(
        privacyTitle: "Privacy",
        privacyMenu: "Privacy…",
        reportMenu: "Report a problem…",
        showWhatIsSent: "Show what is sent",
        nothingToShow: "Nothing to send yet: no game window has reported a status.",
        sentUsageTitle: "Usage statistics, next batch",
        sentDiagnosticsTitle: "Error reports and performance data, next batch",
        nothingSentWhileOff: "Sharing is off. Nothing is sent.",
        deleteData: "Delete my data…",
        downloadData: "Download my data…",
        installId: "Install ID",
        copy: "Copy",
        lastSent: "Last sent",
        notSentYet: "not sent yet",
        serverUnreachable: "server unreachable",
        serverMessage: "Message from the server",
        noInstallYet: "none: sharing is off",
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
        sendAgain: "Send again",
        ok: "OK"
    )
}
