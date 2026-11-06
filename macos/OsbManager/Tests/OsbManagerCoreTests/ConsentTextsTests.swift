import Foundation
import Testing
@testable import OsbManagerCore

struct ConsentTextsTests {
    @Test(arguments: [
        (["tr"], ConsentLanguage.turkish),
        (["tr-TR"], ConsentLanguage.turkish),
        (["tr_TR"], ConsentLanguage.turkish),
        (["TR-tr", "en-US"], ConsentLanguage.turkish),
        (["en-US", "tr"], ConsentLanguage.english),
        (["de-DE"], ConsentLanguage.english),
        (["tracking"], ConsentLanguage.english),
        ([String](), ConsentLanguage.english),
    ])
    func theLanguageFollowsThePreferredLanguage(languages: [String], expected: ConsentLanguage) {
        #expect(ConsentLanguage.preferred(languages) == expected)
    }

    @Test func theConsentVersionMatchesTheLegalText() {
        #expect(TelemetryLimits.consentTextVersion == "2026-11-04.1")
        #expect(TelemetryLimits.consentVersion == 1)
    }

    @Test func noTextCallsUsageStatisticsAnonymous() {
        for language in [ConsentLanguage.english, .turkish] {
            let texts = ConsentTexts.texts(for: language)
            let usage = [texts.firstRunTitle, texts.firstRunBody, texts.usageLabel, texts.usageHelp, texts.stopSharingQuestion, texts.charactersLabel, texts.charactersHelp, texts.deleteQuestion]
            for text in usage {
                #expect(!text.lowercased().contains("anonymous"))
                #expect(!text.lowercased().contains("anonim"))
            }
        }
    }

    @Test func onlyTheReportNoteForAReportWithoutUsageStatisticsSaysAnonymous() {
        #expect(ConsentTexts.english.reportAnonymousNote.contains("anonymous"))
        #expect(ConsentTexts.turkish.reportAnonymousNote.contains("anonim"))
        #expect(!ConsentTexts.english.reportConfirmation.contains("anonymous"))
        #expect(!ConsentTexts.turkish.reportConfirmation.contains("anonim"))
    }

    @Test func theFirstRunPromptHasTheTwoEqualButtonsAndTheRightLinks() {
        #expect(ConsentTexts.english.share == "Share")
        #expect(ConsentTexts.english.noThanks == "No thanks")
        #expect(ConsentTexts.turkish.share == "Paylaş")
        #expect(ConsentTexts.turkish.noThanks == "Hayır, teşekkürler")
        #expect(ConsentTexts.english.privacyPolicyUrl.absoluteString == "https://osb.lol/en/privacy/")
        #expect(ConsentTexts.turkish.privacyPolicyUrl.absoluteString == "https://osb.lol/gizlilik/")
        #expect(ConsentTexts.turkish.kvkkNoticeUrl?.absoluteString == "https://osb.lol/kvkk/aydinlatma-metni/")
        #expect(ConsentTexts.turkish.explicitConsentUrl?.absoluteString == "https://osb.lol/kvkk/acik-riza-metni/")
        #expect(ConsentTexts.english.kvkkNoticeUrl == nil)
        #expect(ConsentTexts.english.explicitConsentUrl == nil)
    }

    @Test func theTextsNameTheRetentionPeriods() {
        #expect(ConsentTexts.english.usageHelp.contains("45 days"))
        #expect(ConsentTexts.english.usageHelp.contains("90 days"))
        #expect(ConsentTexts.turkish.usageHelp.contains("45 gün"))
        #expect(ConsentTexts.turkish.usageHelp.contains("90 gün"))
        #expect(ConsentTexts.english.reportConfirmation.contains("6 months"))
        #expect(ConsentTexts.turkish.reportConfirmation.contains("6 ay"))
        #expect(ConsentTexts.english.screenshotText.contains("30 days"))
        #expect(ConsentTexts.turkish.screenshotText.contains("30 gün"))
    }

    @Test func theReportCodeIsInsertedIntoTheSentMessage() {
        #expect(ConsentTexts.english.reportSent(code: "R-7K3Q9XAB") == "Sent. Your report code is R-7K3Q9XAB. Keep it if you want the report deleted later.")
        #expect(ConsentTexts.turkish.reportSent(code: "R-7K3Q9XAB") == "Gönderildi. Rapor kodun R-7K3Q9XAB. Raporun daha sonra silinmesini istersen bu kodu sakla.")
    }

    @Test func everyInterfaceTextExistsInBothLanguages() {
        let english = Mirror(reflecting: InterfaceTexts.english).children.compactMap { $0.value as? String }
        let turkish = Mirror(reflecting: InterfaceTexts.turkish).children.compactMap { $0.value as? String }

        #expect(english.count == turkish.count)
        #expect(english.allSatisfy { !$0.isEmpty })
        #expect(turkish.allSatisfy { !$0.isEmpty })
    }
}
