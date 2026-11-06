import Foundation
import Testing
@testable import OsbManagerCore

struct AppSettingsTests {
    @Test func defaultsToSixtyFramesASecond() {
        let temp = TemporaryDirectory()

        let settings = AppSettings.load(from: temp.file("settings.json"))

        #expect(settings.frameLimit == 60)
    }

    @Test func offersTheWindowsFrameLimits() {
        #expect(AppSettings.frameLimits == [30, 60, 120, 0])
    }

    @Test func keepsTheChosenValues() throws {
        let temp = TemporaryDirectory()
        let settings = AppSettings.load(from: temp.file("settings.json"))
        settings.frameLimit = 0
        try settings.save()

        let reloaded = AppSettings.load(from: temp.file("settings.json"))

        #expect(reloaded.frameLimit == 0)
    }

    @Test(arguments: [#"{"frameLimit":7}"#, #"{"frameLimit":-1}"#, "not json", #"{"frameLimit":"60"}"#])
    func fallsBackToTheDefaultForUnknownValues(json: String) throws {
        let temp = TemporaryDirectory()
        try json.write(to: temp.file("settings.json"), atomically: true, encoding: .utf8)

        #expect(AppSettings.load(from: temp.file("settings.json")).frameLimit == AppSettings.defaultFrameLimit)
    }

    @Test func keepsTheHideStarChoiceAndLoadsOldFilesWithItOff() throws {
        let temp = TemporaryDirectory()
        try #"{"frameLimit":60,"shareGameFiles":true}"#.write(to: temp.file("settings.json"), atomically: true, encoding: .utf8)
        let settings = AppSettings.load(from: temp.file("settings.json"))
        #expect(!settings.hideStarSox)

        settings.hideStarSox = true
        try settings.save()

        #expect(AppSettings.load(from: temp.file("settings.json")).hideStarSox)
        #expect(try String(contentsOf: temp.file("settings.json"), encoding: .utf8).contains("\"hideStarSox\" : true"))
        #expect(!AppSettings.load(from: temp.file("missing.json")).hideStarSox)
    }

    @Test func writesTheWindowsFieldName() throws {
        let temp = TemporaryDirectory()
        let settings = AppSettings.load(from: temp.file("settings.json"))
        try settings.save()

        let text = try String(contentsOf: temp.file("settings.json"), encoding: .utf8)

        #expect(text.contains("\"frameLimit\" : 60"))
        #expect(!text.contains("timerShim"))
    }
}
