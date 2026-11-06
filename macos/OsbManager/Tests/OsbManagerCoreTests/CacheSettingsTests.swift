import Foundation
import Testing
@testable import OsbManagerCore

struct CacheSettingsAndTextTests {
    @Test func theSharedCacheSettingIsOnByDefaultAndIsKept() throws {
        let temp = TemporaryDirectory()
        let settings = AppSettings.load(from: temp.file("settings.json"))
        #expect(settings.shareGameFiles)
        settings.shareGameFiles = false
        try settings.save()

        #expect(!AppSettings.load(from: temp.file("settings.json")).shareGameFiles)
        let text = try String(contentsOf: temp.file("settings.json"), encoding: .utf8)
        #expect(text.contains("\"shareGameFiles\" : false"))
    }

    @Test func settingsFilesWithoutTheKeyTurnItOnAndAnExplicitChoiceStays() throws {
        let temp = TemporaryDirectory()
        try #"{"frameLimit":30,"timerShim":false}"#.write(to: temp.file("settings.json"), atomically: true, encoding: .utf8)
        #expect(AppSettings.load(from: temp.file("settings.json")).shareGameFiles)

        try #"{"frameLimit":30,"shareGameFiles":false}"#.write(to: temp.file("settings.json"), atomically: true, encoding: .utf8)
        let explicit = AppSettings.load(from: temp.file("settings.json"))
        #expect(!explicit.shareGameFiles && explicit.frameLimit == 30)
    }

    @Test func putsThePackCacheInTheDataFolder() {
        #expect(AppPaths(root: URL(fileURLWithPath: "/tmp/sro-data")).packCache.path == "/tmp/sro-data/packcache")
    }

    @Test(arguments: [(Int64(512), "512 B"), (54 << 20, "54 MB"), (5 << 29, "2.5 GB"), (2048, "2 KB"), (0, "0 B")])
    func formatsSizes(bytes: Int64, expected: String) {
        #expect(Format.bytes(bytes, locale: Locale(identifier: "en_US")) == expected)
    }

    @Test func writesTheWindowsFooterText() {
        let english = Locale(identifier: "en_US")
        let quiet = CacheCounters(diskBytes: 54 << 20, packs: 2, servedFromDisk: 5 << 20, downloaded: 49 << 20, failures: 0)
        let failed = CacheCounters(diskBytes: 54 << 20, packs: 2, servedFromDisk: 5 << 20, downloaded: 49 << 20, failures: 3)

        #expect(CacheText.line(quiet, locale: english) == "shared cache 54 MB (2 packs) · served from disk 5 MB · downloaded 49 MB")
        #expect(CacheText.line(failed, locale: english) == "shared cache 54 MB (2 packs) · served from disk 5 MB · downloaded 49 MB · 3 fell back to the browser")
        #expect(FooterText.line(botVersion: "1.2.172", cache: CacheText.line(quiet, locale: english)) == "Bot 1.2.172 · shared cache 54 MB (2 packs) · served from disk 5 MB · downloaded 49 MB")
    }

    @Test func dropsTheCacheNoteOfTheOldPageShim() {
        #expect(PageMessageInbox.accept(body: #"{"type":"cache-note","note":"no-worker"}"#, isMainFrame: true, scheme: "https", host: "opensro.online", port: 0) == nil)
    }
}
