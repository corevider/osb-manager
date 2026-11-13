import Foundation
import Testing
@testable import OsbManagerCore

struct ConsentTextsTests {
    static let windowsTextsFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("src/OsbManager.Core/Telemetry/PrivacyTexts.cs")

    static func macTextsByWindowsName() -> [String: String] {
        let texts = ConsentTexts.english
        let interface = InterfaceTexts.english
        return [
            "FirstRunTitle": texts.firstRunTitle,
            "FirstRunChangedLead": texts.firstRunChangedLead,
            "FirstRunText": texts.firstRunBody,
            "FirstRunShare": texts.share,
            "FirstRunDecline": texts.noThanks,
            "FirstRunClose": texts.closeAsNoThanks,
            "FirstRunWhat": texts.whatIsSent,
            "PolicyLink": texts.privacyPolicy,
            "PolicyUrl": texts.privacyPolicyUrl.absoluteString,
            "KvkkNoticeLink": texts.kvkkNotice,
            "KvkkNoticeUrl": texts.kvkkNoticeUrl.absoluteString,
            "KvkkConsentLink": texts.explicitConsent,
            "KvkkConsentUrl": texts.explicitConsentUrl.absoluteString,
            "UsageLabel": texts.usageLabel,
            "UsageHelp": texts.usageHelp,
            "StopConfirm": texts.stopSharingQuestion,
            "CharactersLabel": texts.charactersLabel,
            "CharactersHelp": texts.charactersHelp,
            "DeleteConfirm": texts.deleteQuestion,
            "ReportNotice": texts.reportConfirmation,
            "ReportNoticeAnonymous": texts.reportAnonymousNote,
            "AddScreenshot": texts.screenshotButton,
            "ScreenshotNotice": texts.screenshotText,
            "RemoveScreenshot": texts.screenshotRemove,
            "SentWithCode": texts.reportSent(code: "{0}"),
            "PrivacyTitle": interface.privacyTitle,
            "PrivacyMenu": interface.privacyMenu,
            "ReportMenu": interface.reportMenu,
            "ReportTitle": interface.reportTitle,
            "ShowSent": interface.showWhatIsSent,
            "SentUsageTitle": interface.sentUsageTitle,
            "SentDiagnosticsTitle": interface.sentDiagnosticsTitle,
            "InstallId": interface.installId,
            "Copy": interface.copy,
            "Close": interface.close,
            "LastSent": interface.lastSent,
            "NotSentYet": interface.notSentYet,
            "ServerUnreachable": interface.serverUnreachable,
            "ServerMessage": interface.serverMessage,
            "Kind": interface.kind,
            "KindBug": interface.bug,
            "KindFeature": interface.feature,
            "Preview": interface.preview,
            "Send": interface.send,
            "Cancel": interface.cancel,
            "SendAgain": interface.sendAgain,
            "ScreenshotFailed": interface.screenshotFailed,
        ]
    }

    @Test func everyConsentTextEqualsTheWindowsEnglishText() throws {
        let source = try String(contentsOf: Self.windowsTextsFile, encoding: .utf8)
        let windows = try CSharpTexts.englishTexts(in: source)
        #expect(windows.count > 60)
        for (name, mac) in Self.macTextsByWindowsName() {
            let expected = try #require(windows[name], "PrivacyTexts.English has no \(name)")
            #expect(mac == expected.replacingOccurrences(of: "\r\n", with: "\n"), "\(name) differs from Windows")
        }
    }

    @Test func theTextsAreEnglishOnly() {
        let strings = Mirror(reflecting: ConsentTexts.english).children.compactMap { $0.value as? String }
            + Mirror(reflecting: InterfaceTexts.english).children.compactMap { $0.value as? String }
        #expect(strings.count > 60)
        for text in strings {
            #expect(!text.isEmpty)
            #expect(text.unicodeScalars.allSatisfy { $0.isASCII || "…".unicodeScalars.contains($0) }, "\(text) is not English")
        }
    }

    @Test(arguments: [
        (["tr"], "tr"),
        (["tr-TR"], "tr"),
        (["tr_TR"], "tr"),
        (["TR-tr", "en-US"], "tr"),
        (["en-US", "tr"], "en"),
        (["de-DE"], "de"),
        (["zh-Hans-CN"], "zh"),
        (["tracking"], "en"),
        (["ü1"], "en"),
        ([String](), "en"),
    ])
    func theLocaleIsDataAndFollowsThePreferredLanguage(languages: [String], expected: String) {
        #expect(InterfaceLocale.code(languages) == expected)
    }

    @Test func theConsentVersionMatchesTheLegalText() {
        #expect(TelemetryLimits.consentTextVersion == "2026-11-12.1")
        #expect(TelemetryLimits.consentVersion == 2)
    }

    @Test func theKvkkLinksAreShownToEveryoneAndLabelledTurkish() {
        let texts = ConsentTexts.english
        #expect(texts.kvkkNotice == "KVKK notice (Turkish)")
        #expect(texts.explicitConsent == "KVKK explicit consent (Turkish)")
        #expect(texts.kvkkNoticeUrl.absoluteString == "https://osb.lol/kvkk/aydinlatma-metni/")
        #expect(texts.explicitConsentUrl.absoluteString == "https://osb.lol/kvkk/acik-riza-metni/")
        #expect(texts.privacyPolicyUrl.absoluteString == "https://osb.lol/en/privacy/")
    }

    @Test func noMainTextCallsTheDataAnonymous() {
        let texts = ConsentTexts.english
        for text in [texts.firstRunTitle, texts.firstRunChangedLead, texts.firstRunBody, texts.usageLabel, texts.stopSharingQuestion, texts.charactersLabel, texts.charactersHelp, texts.deleteQuestion, texts.reportConfirmation] {
            #expect(!text.lowercased().contains("anonymous"))
        }
        #expect(texts.reportAnonymousNote.contains("anonymous"))
    }

    @Test func theReportCodeIsInsertedIntoTheSentMessage() {
        #expect(ConsentTexts.english.reportSent(code: "R-7K3Q9XAB") == "Sent. Your report code is R-7K3Q9XAB. Keep it if you want the report deleted later.")
    }
}

enum CSharpTexts {
    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    static func englishTexts(in source: String) throws -> [String: String] {
        let constants = try constantsOf(source)
        guard let start = source.range(of: "public static PrivacyTexts English { get; } = new()") else {
            throw ParseError(description: "no English block")
        }
        let body = source[start.upperBound...]
        guard let end = body.range(of: "\n    };") else { throw ParseError(description: "no end of the English block") }
        var texts: [String: String] = [:]
        var scanner = Scanner(String(body[..<end.lowerBound]))
        while let name = scanner.nextAssignment() {
            texts[name] = try scanner.expression(constants: constants)
        }
        return texts
    }

    private static func constantsOf(_ source: String) throws -> [String: String] {
        var constants: [String: String] = [:]
        for line in source.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("private const string ") || trimmed.hasPrefix("public const string ") else { continue }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[..<equals].split(separator: " ").last.map(String.init) ?? ""
            var scanner = Scanner(String(trimmed[trimmed.index(after: equals)...]))
            if let value = try? scanner.expression(constants: constants) {
                constants[name] = value
            }
        }
        return constants
    }

    struct Scanner {
        private let characters: [Character]
        private var index = 0

        init(_ text: String) {
            characters = Array(text)
        }

        mutating func nextAssignment() -> String? {
            while index < characters.count {
                skipSpace()
                let start = index
                while index < characters.count, characters[index].isLetter || characters[index].isNumber { index += 1 }
                let name = String(characters[start..<index])
                skipSpace()
                if !name.isEmpty, index < characters.count, characters[index] == "=" {
                    index += 1
                    return name
                }
                index = max(index, start + 1)
            }
            return nil
        }

        mutating func expression(constants: [String: String]) throws -> String {
            var result = ""
            while true {
                skipSpace()
                guard index < characters.count else { return result }
                if characters[index] == "\"" {
                    result += try literal()
                } else {
                    let start = index
                    while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "." { index += 1 }
                    let name = String(characters[start..<index]).split(separator: ".").last.map(String.init) ?? ""
                    guard let value = constants[name] else { throw ParseError(description: "unknown value \(name)") }
                    result += value
                }
                skipSpace()
                guard index < characters.count, characters[index] == "+" else { return result }
                index += 1
            }
        }

        private mutating func literal() throws -> String {
            index += 1
            var result = ""
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == "\"" { return result }
                if character == "\\", index < characters.count {
                    let escaped = characters[index]
                    index += 1
                    switch escaped {
                    case "r": result.append("\r")
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    default: result.append(escaped)
                    }
                } else {
                    result.append(character)
                }
            }
            throw ParseError(description: "open string")
        }

        private mutating func skipSpace() {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
        }
    }
}
