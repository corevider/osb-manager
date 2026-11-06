import Foundation
import JavaScriptCore
import Testing
@testable import OsbManagerCore

private let english = Locale(identifier: "en_US")

private final class Clock {
    var now: Date

    init(_ now: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        self.now = now
    }
}

struct SoxLogTests {
    @Test(arguments: [
        ("hunter has dropped Demon Polearm (Seal Of Star) from Wing Tribe Chaser", "hunter", "Demon Polearm", "Star", "Wing Tribe Chaser"),
        ("(Notice):healer has dropped Blaze Diadem (Seal Of Moon) from Wing Tribe Chaser", "healer", "Blaze Diadem", "Moon", "Wing Tribe Chaser"),
        ("SEAL OF SUN: sorcerer has dropped Lynx Valor Phantom (Seal Of Sun) from Tiger Woman.", "sorcerer", "Lynx Valor Phantom", "Sun", "Tiger Woman"),
        ("bard has dropped Sapphire Ring (Seal Of Star)", "bard", "Sapphire Ring", "Star", ""),
        ("SEAL OF SUN: bard has dropped Lynx Blade from Tiger Woman.", "bard", "Lynx Blade", "Sun", "Tiger Woman"),
        ("SEAL OF SUN: bard has dropped Lynx Blade", "bard", "Lynx Blade", "Sun", ""),
        ("minstrel has dropped Moon Blade (seal of moon) from Mob", "minstrel", "Moon Blade", "Moon", "Mob"),
        ("seal of sun: bard has dropped Lynx Blade from Tiger Woman", "bard", "Lynx Blade", "Sun", "Tiger Woman"),
    ])
    func readsDropAnnouncements(text: String, who: String, item: String, seal: String, from: String) {
        #expect(SoxLog.parse(text) == SoxAnnouncement(character: who, item: item, seal: seal, monster: from))
    }

    @Test(arguments: ["", "   ", "hunter has dropped Demon Polearm from Wing Tribe Chaser", "The server will restart in 5 minutes.", "x has dropped"])
    func ignoresOtherNotices(text: String) {
        #expect(SoxLog.parse(text) == nil)
        #expect(SoxLog.parse(nil) == nil)
    }

    @Test func keepsOneCopyOfAnAnnouncementSeveralWindowsSaw() {
        let temp = TemporaryDirectory()
        let clock = Clock()
        let log = SoxLog(url: temp.file("sox.json"), clock: { clock.now })
        let text = "hunter has dropped Demon Polearm (Seal Of Star) from Wing Tribe Chaser"

        #expect(log.add(text, seenBy: "hunter", ours: ["hunter"]) != nil)
        #expect(log.add(text, seenBy: "bot", ours: ["hunter"]) == nil)
        clock.now.addTimeInterval(180)
        #expect(log.add(text, seenBy: "bot", ours: ["hunter"]) != nil)
        #expect(log.drops.count == 2)
    }

    @Test func keepsOneCopyOfASunDropSeenAsBannerAndAsChat() {
        let temp = TemporaryDirectory()
        let log = SoxLog(url: temp.file("sox.json"))

        #expect(log.add("SEAL OF SUN: hunter has dropped Lynx Blade from Tiger Woman", seenBy: "hunter", ours: []) != nil)
        #expect(log.add("hunter has dropped Lynx Blade (Seal Of Sun) from Tiger Woman", seenBy: "bot", ours: []) == nil)
        #expect(log.drops.map(\.seal) == ["Sun"])
    }

    @Test func comparesTheSameDropWithoutRegardToCase() {
        let temp = TemporaryDirectory()
        let log = SoxLog(url: temp.file("sox.json"))

        #expect(log.add("hunter has dropped Demon Polearm (Seal Of Star) from Mob", seenBy: "a", ours: []) != nil)
        #expect(log.add("HUNTER has dropped demon polearm (Seal Of Star) from Mob", seenBy: "b", ours: []) == nil)
    }

    @Test func marksOurCharactersAndKeepsTheListForTheNextStart() throws {
        let temp = TemporaryDirectory()
        let log = SoxLog(url: temp.file("sox.json"))
        var added: [SoxDrop] = []
        log.onAdded = { added.append($0) }

        log.add("Hunter has dropped Demon Polearm (Seal Of Star) from Wing Tribe Chaser", seenBy: "hunter", ours: ["hunter", "bard"])
        log.add("stranger has dropped Blaze Diadem (Seal Of Moon) from Wing Tribe Chaser", seenBy: "hunter", ours: ["hunter", "bard"])
        log.add("not a drop", seenBy: "hunter", ours: ["hunter"])

        #expect(added.map(\.ours) == [true, false])
        let reloaded = SoxLog(url: temp.file("sox.json"))
        #expect(reloaded.drops.count == 2)
        #expect(reloaded.drops[0].item == "Demon Polearm")
        #expect(reloaded.drops.map(\.text) == log.drops.map(\.text))
        #expect(reloaded.drops.map(\.ours) == [true, false])
        try reloaded.clear()
        #expect(SoxLog(url: temp.file("sox.json")).drops.isEmpty)
    }

    @Test func keepsOnlyTheNewestDrops() {
        let temp = TemporaryDirectory()
        let clock = Clock()
        let log = SoxLog(url: temp.file("sox.json"), clock: {
            clock.now.addTimeInterval(1)
            return clock.now
        })

        for index in 0..<(SoxLog.capacity + 5) {
            log.add("p\(index) has dropped Item \(index) (Seal Of Star) from Mob", seenBy: "a", ours: [])
        }

        #expect(log.drops.count == SoxLog.capacity)
        #expect(log.drops.first?.item == "Item 5")
        #expect(SoxLog(url: temp.file("sox.json")).drops.count == SoxLog.capacity)
    }

    @Test func keepsOnlyTheNewestDropsOfAFileThatIsTooLong() throws {
        let temp = TemporaryDirectory()
        let entries = (0..<(SoxLog.capacity + 7)).map {
            #"{"at":"2026-10-30T12:00:00","character":"c\#($0)","item":"Item \#($0)","seal":"Star","monster":"","text":"t\#($0)","ours":false,"seenBy":"a"}"#
        }
        try "[\(entries.joined(separator: ","))]".write(to: temp.file("sox.json"), atomically: true, encoding: .utf8)

        let log = SoxLog(url: temp.file("sox.json"))

        #expect(log.drops.count == SoxLog.capacity)
        #expect(log.drops.first?.item == "Item 7")
        #expect(log.drops.last?.item == "Item \(SoxLog.capacity + 6)")
    }

    @Test func startsEmptyWhenTheFileIsNotJson() throws {
        let temp = TemporaryDirectory()
        try "not json".write(to: temp.file("sox.json"), atomically: true, encoding: .utf8)

        let log = SoxLog(url: temp.file("sox.json"))

        #expect(log.drops.isEmpty)
        #expect(log.add("a has dropped B (Seal Of Star) from C", seenBy: "x", ours: []) != nil)
        #expect(SoxLog(url: temp.file("sox.json")).drops.count == 1)
    }

    @Test func dropsBrokenEntriesButKeepsTheGoodOnes() throws {
        let temp = TemporaryDirectory()
        try """
        [
          {"at":"2026-10-30T12:00:00","character":"a","item":"One","seal":"Star","monster":"M","text":"t1","ours":true,"seenBy":"x"},
          {"at":"yesterday","character":"b","item":"Two","seal":"Moon","monster":"M","text":"t2","ours":false,"seenBy":"x"},
          {"character":"c","item":"Three","seal":"Sun"},
          "garbage",
          null,
          {"at":"2026-10-30T12:01:00","character":"d","item":"Four","seal":"Sun","monster":"M","text":"t4","ours":false,"seenBy":"x"}
        ]
        """.write(to: temp.file("sox.json"), atomically: true, encoding: .utf8)

        let log = SoxLog(url: temp.file("sox.json"))

        #expect(log.drops.map(\.item) == ["One", "Four"])
    }

    @Test func readsTheWindowsDateFormats() throws {
        let calendar = Calendar.current
        for text in ["2026-10-30T12:00:00", "2026-10-30T12:00:00.1234567", "2026-10-30T12:00:00.5"] {
            let date = try #require(SoxDateCoding.date(from: text))
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            #expect(parts.year == 2026 && parts.month == 10 && parts.day == 30 && parts.hour == 12 && parts.minute == 0 && parts.second == 0)
        }
        let utc = try #require(SoxDateCoding.date(from: "2026-10-30T12:00:00Z"))
        let offset = try #require(SoxDateCoding.date(from: "2026-10-30T14:00:00+02:00"))
        #expect(utc == offset)
        #expect(SoxDateCoding.date(from: "30/10/2026") == nil)
    }

    @Test func writesTheWindowsFieldNames() throws {
        let temp = TemporaryDirectory()
        let log = SoxLog(url: temp.file("sox.json"))
        log.add("hunter has dropped Demon Polearm (Seal Of Star) from Wing Tribe Chaser", seenBy: "alpha", ours: ["hunter"])

        let entries = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: temp.file("sox.json"))) as? [[String: Any]])
        let entry = try #require(entries.first)

        #expect(Set(entry.keys) == ["at", "character", "item", "seal", "monster", "text", "ours", "seenBy", "receivedBy"])
        #expect(entry["ours"] as? Bool == true)
        #expect((entry["at"] as? String)?.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}$"#, options: .regularExpression) != nil)
    }
}

struct StatsTotalsTests {
    @Test func addsTheAccountsRatesAndShowsTheLongestSession() throws {
        let total = StatsTotals.sum([
            StatsLine(milliseconds: 4_080_000, kills: 288, experience: 0, gold: 175_590_000, deaths: 0, sox: 1),
            StatsLine(milliseconds: 4_140_000, kills: 273, experience: 2_780_000, gold: 197_330_000, deaths: 3, sox: 2),
        ])

        #expect(total.milliseconds == 4_140_000)
        #expect(total.kills == 561)
        #expect(abs(try #require(total.killsPerHour) - (254.1 + 237.4)) < 0.1)
        #expect(total.experience == 2_780_000)
        #expect(total.deaths == 3)
        #expect(total.sox == 3)
    }

    @Test func leavesOutRatesOfSessionsShorterThanThirtySeconds() {
        let total = StatsTotals.sum([
            StatsLine(milliseconds: 3_600_000, kills: 100, experience: nil, gold: nil, deaths: 0, sox: 0),
            StatsLine(milliseconds: 10_000, kills: 5, experience: nil, gold: nil, deaths: 0, sox: 0),
        ])

        #expect(total.killsPerHour == 100)
        #expect(total.experiencePerHour == nil)
        #expect(Format.perHour(rate: total.killsPerHour, locale: english) == "100")
        #expect(Format.perHour(rate: total.experiencePerHour, locale: english) == "—")
    }

    @Test func handlesNoLines() {
        let total = StatsTotals.sum([])

        #expect(total.milliseconds == 0 && total.kills == 0 && total.killsPerHour == nil)
    }
}

struct FormatStatsTests {
    @Test(arguments: [
        (Int64(288), "288"), (54_321, "54,321"), (175_590_000, "175.59M"), (2_780_000, "2.78M"),
        (1_685_416_273, "1.69B"), (-2_500_000, "-2.5M"), (123_456, "123.5K"), (99_999, "99,999"), (100_000, "100K"),
    ])
    func compactsLargeNumbers(value: Int64, expected: String) {
        #expect(Format.compact(value, locale: english) == expected)
    }

    @Test func showsAMissingNumber() {
        #expect(Format.compact(nil, locale: english) == "—")
    }

    @Test(arguments: [(Int64(0), "0m"), (59_000, "0m"), (4_080_000, "1h 08m"), (8_220_000, "2h 17m"), (-5, "0m")])
    func formatsHuntingTime(milliseconds: Int64, expected: String) {
        #expect(Format.duration(milliseconds: milliseconds) == expected)
    }

    @Test func showsRatesOnlyAfterThirtySeconds() {
        #expect(Format.perHour(10, milliseconds: 29_999, locale: english) == "—")
        #expect(Format.perHour(288, milliseconds: 4_114_286, locale: english) == "252")
        #expect(Format.perHour(nil, milliseconds: 60_000, locale: english) == "—")
        #expect(Format.perHour(rate: nil, locale: english) == "—")
    }
}

struct StatsTableTests {
    private let started = Date(timeIntervalSince1970: 1_790_000_000)

    private func drop(_ character: String, ours: Bool, after seconds: TimeInterval) -> SoxDrop {
        SoxDrop(at: started.addingTimeInterval(seconds), character: character, item: "Item", seal: "Star", monster: "Mob", text: "t", ours: ours, seenBy: "a")
    }

    private let alpha = StatsEntry(account: "alpha", character: "hunter", session: SessionStats(milliseconds: 4_080_000, kills: 288, deaths: 0, experience: 0, gold: -175_590_000))
    private let beta = StatsEntry(account: "beta", character: "bard", session: SessionStats(milliseconds: 4_140_000, kills: 273, deaths: 3, experience: 2_780_000, gold: 197_330_000))

    @Test func formatsOneRowPerAccount() throws {
        let rows = StatsTable.rows(entries: [alpha], drops: [], since: started, locale: english)

        #expect(rows.count == 1)
        #expect(rows[0].cells == ["alpha", "hunter", "1h 08m", "288", "254", "0", "0", "-175.59M", "-154.93M", "0", "0"])
        #expect(!rows[0].bold)
    }

    @Test func addsABoldTotalRowFromTwoAccounts() throws {
        let rows = StatsTable.rows(entries: [alpha, beta], drops: [], since: started, locale: english)

        #expect(rows.count == 3)
        let total = rows[2]
        #expect(total.bold)
        #expect(total.cells[0] == "All characters")
        #expect(total.cells[2] == "1h 09m")
        #expect(total.cells[3] == "561")
        #expect(total.cells[9] == "3")
        #expect(StatsTable.columns.count == total.cells.count)
    }

    @Test func countsOnlyOurDropsSinceTheAppStarted() {
        let drops = [
            drop("hunter", ours: true, after: 10),
            drop("HUNTER", ours: true, after: 20),
            drop("hunter", ours: true, after: -3600),
            drop("hunter", ours: false, after: 30),
            drop("bard", ours: true, after: 40),
        ]

        let rows = StatsTable.rows(entries: [alpha, beta], drops: drops, since: started, locale: english)

        #expect(rows[0].cells[10] == "2")
        #expect(rows[1].cells[10] == "1")
        #expect(rows[2].cells[10] == "3")
    }

    @Test func hasNoRowsWithoutSessions() {
        #expect(StatsTable.rows(entries: [], drops: [], since: started, locale: english).isEmpty)
    }
}

struct SoxReceiptTests {
    private let announcement = "Hunter has dropped Star Blade (Seal Of Star) from Wing Tribe Chaser"

    private func party(_ item: String, _ member: String, inParty: Bool = true) -> SoxReceipt {
        SoxReceipt(key: "UIIT_MSG_PARTYGET_ITEM_EXPENDABLE", item: item, member: member, inParty: inParty, count: 1)
    }

    private func own(_ item: String) -> SoxReceipt {
        SoxReceipt(key: "UIIT_MSG_STATE_GET_ITEM_EXPENDABLE", item: item, member: "", inParty: false, count: 1)
    }

    private func create(_ temp: TemporaryDirectory) -> (SoxLog, Clock) {
        let clock = Clock()
        return (SoxLog(url: temp.file("sox.json"), clock: { clock.now }), clock)
    }

    @Test(arguments: [
        ("UIIT_MSG_PARTYGET_ITEM_EXPENDABLE", true), ("UIIT_MSG_STATE_GET_ITEM_EXPENDABLE", true), ("UIIT_MSG_PARTYGET_ITEM", true),
        ("UIIT_MSG_STATE_GET_ITEM_EQUIP", true), ("UIIT_MSG_PARTYGET_GOLD", false), ("UIIT_MSG_STATE_GAIN_GOLD", false), ("uiit_msg_partyget_item", false),
    ])
    func knowsTheItemPickupKeys(key: String, wanted: Bool) {
        #expect(SoxReceipt.isReceiveKey(key) == wanted)
    }

    @Test func tellsTheReceiverOnlyWhenSure() {
        #expect(party("Star Blade", "Bard").receiver(ownCharacter: "Hunter") == "Bard")
        #expect(party("Star Blade", "Bard", inParty: false).receiver(ownCharacter: "Hunter") == nil)
        #expect(party("Star Blade", "").receiver(ownCharacter: "Hunter") == nil)
        #expect(own("Star Blade").receiver(ownCharacter: "Hunter") == "Hunter")
        #expect(own("Star Blade").receiver(ownCharacter: nil) == nil)
    }

    @Test func readsPickupNoticesFromTheStatus() throws {
        let status = try #require(BotStatus.parse("""
        {"type":"status","received":[
          {"key":"UIIT_MSG_PARTYGET_ITEM_EXPENDABLE","item":"Star Blade","count":1,"member":"Bard","inParty":true},
          {"key":"UIIT_MSG_STATE_GET_ITEM_EXPENDABLE","item":"HP Potion","count":5,"member":"","inParty":false},
          {"key":"UIIT_MSG_PARTYGET_GOLD","item":"100","member":"Bard","inParty":true},
          {"key":"UIIT_MSG_PARTYGET_ITEM","item":"","member":"Bard"},
          "text"
        ]}
        """))

        #expect(status.received == [
            SoxReceipt(key: "UIIT_MSG_PARTYGET_ITEM_EXPENDABLE", item: "Star Blade", member: "Bard", inParty: true, count: 1),
            SoxReceipt(key: "UIIT_MSG_STATE_GET_ITEM_EXPENDABLE", item: "HP Potion", member: "", inParty: false, count: 5),
        ])
        #expect(BotStatus.parse(#"{"type":"status"}"#)?.received == [])
    }

    @Test func matchesAPickupAfterTheAnnouncement() {
        let temp = TemporaryDirectory()
        let (log, clock) = create(temp)
        var updated: [SoxDrop] = []
        log.onUpdated = { updated.append($0) }

        log.add(announcement, seenBy: "alpha", ours: ["Hunter"])
        clock.now.addTimeInterval(20)
        let result = log.receive(party("star blade", "Bard"), ownCharacter: "Hunter")

        #expect(result.outcome == .matched)
        #expect(log.drops.map(\.receivedBy) == ["Bard"])
        #expect(updated.map(\.receivedBy) == ["Bard"])
        #expect(!result.shouldLog)
    }

    @Test func matchesAPickupThatCameBeforeTheAnnouncement() {
        let temp = TemporaryDirectory()
        let (log, clock) = create(temp)

        #expect(log.receive(party("Star Blade", "Bard"), ownCharacter: "Hunter").outcome == .waiting)
        clock.now.addTimeInterval(90)

        #expect(log.add(announcement, seenBy: "alpha", ours: ["Hunter"])?.receivedBy == "Bard")
    }

    @Test func leavesTheCellEmptyWhenNothingMatches() {
        let temp = TemporaryDirectory()
        let (log, clock) = create(temp)

        log.receive(party("Star Blade", "Bard"), ownCharacter: "Hunter")
        clock.now.addTimeInterval(180)
        log.add(announcement, seenBy: "alpha", ours: ["Hunter"])
        log.receive(party("Moon Shield", "Bard"), ownCharacter: "Hunter")
        log.receive(party("Star Blade", "Stranger", inParty: false), ownCharacter: "Hunter")

        #expect(log.drops.map(\.receivedBy) == [""])
    }

    @Test func ignoresAPickupMoreThanTenMinutesLate() {
        let temp = TemporaryDirectory()
        let (log, clock) = create(temp)

        log.add(announcement, seenBy: "alpha", ours: ["Hunter"])
        clock.now.addTimeInterval(601)
        let result = log.receive(party("Star Blade", "Bard"), ownCharacter: "Hunter")

        #expect(result.outcome == .waiting)
        #expect(result.shouldLog)
        #expect(log.drops.map(\.receivedBy) == [""])
    }

    @Test func givesTwoDropsOfTheSameItemOnePickupEach() {
        let temp = TemporaryDirectory()
        let (log, clock) = create(temp)

        log.add(announcement, seenBy: "alpha", ours: ["Hunter"])
        clock.now.addTimeInterval(180)
        log.add("Bard has dropped Star Blade (Seal Of Star) from Wing Tribe Chaser", seenBy: "alpha", ours: ["Hunter"])
        clock.now.addTimeInterval(5)
        log.receive(party("Star Blade", "Bard"), ownCharacter: "Hunter")
        clock.now.addTimeInterval(30)
        log.receive(own("Star Blade"), ownCharacter: "Hunter")

        #expect(log.drops.map(\.receivedBy) == ["Hunter", "Bard"])
    }

    @Test func countsAPickupSeveralWindowsSawOnce() {
        let temp = TemporaryDirectory()
        let (log, clock) = create(temp)

        log.receive(party("Star Blade", "Bard"), ownCharacter: "Hunter")
        clock.now.addTimeInterval(1)
        #expect(log.receive(own("Star Blade"), ownCharacter: "Bard").outcome == .repeated)
        log.add(announcement, seenBy: "alpha", ours: ["Hunter"])
        clock.now.addTimeInterval(60)
        log.add("Other has dropped Star Blade (Seal Of Star) from Wing Tribe Chaser", seenBy: "alpha", ours: ["Hunter"])

        #expect(log.drops.map(\.receivedBy) == ["Bard", ""])
    }

    @Test func fillsTheReceiverFromTheFirstWindowThatCanTell() {
        let temp = TemporaryDirectory()
        let (log, clock) = create(temp)

        log.add(announcement, seenBy: "alpha", ours: ["Hunter"])
        #expect(log.receive(party("Star Blade", "Bard", inParty: false), ownCharacter: "Hunter").outcome == .unknown)
        clock.now.addTimeInterval(1)
        #expect(log.receive(party("Star Blade", "Bard"), ownCharacter: "Cleric").outcome == .matched)

        #expect(log.drops.map(\.receivedBy) == ["Bard"])
    }

    @Test func logsANewUnknownKeyOnceAndNeverThePotions() {
        let temp = TemporaryDirectory()
        let (log, _) = create(temp)
        let equip = SoxReceipt(key: "UIIT_MSG_PARTYGET_ITEM_EQUIP", item: "Plain Blade", member: "Bard", inParty: true, count: 1)

        #expect(!log.receive(own("HP Potion"), ownCharacter: "Hunter").shouldLog)
        #expect(!log.receive(own("HP Potion"), ownCharacter: "Hunter").shouldLog)
        #expect(log.receive(equip, ownCharacter: "Hunter").shouldLog)
        #expect(!log.receive(SoxReceipt(key: equip.key, item: "Plain Shield", member: "Bard", inParty: true, count: 1), ownCharacter: "Hunter").shouldLog)
    }

    @Test func keepsTheReceiverForTheNextStartAndLoadsOldListsWithoutIt() throws {
        let temp = TemporaryDirectory()
        let (log, _) = create(temp)
        log.add(announcement, seenBy: "alpha", ours: ["Hunter"])
        log.receive(party("Star Blade", "Bard"), ownCharacter: "Hunter")

        #expect(SoxLog(url: temp.file("sox.json")).drops.map(\.receivedBy) == ["Bard"])

        try """
        [{"at":"2026-10-30T12:00:00","character":"Hunter","item":"Star Blade","seal":"Star","monster":"Mob","text":"t","ours":true,"seenBy":"alpha"}]
        """.write(to: temp.file("old.json"), atomically: true, encoding: .utf8)
        let old = SoxLog(url: temp.file("old.json")).drops
        #expect(old.map(\.seenBy) == ["alpha"])
        #expect(old.map(\.receivedBy) == [""])
    }

    @Test func readsTheWindowsFileWithTheReceiver() throws {
        let temp = TemporaryDirectory()
        try """
        [{"at":"2026-10-30T12:00:00","character":"Hunter","item":"Star Blade","seal":"Star","monster":"Mob","text":"t","ours":true,"seenBy":"alpha","receivedBy":"Bard"}]
        """.write(to: temp.file("sox.json"), atomically: true, encoding: .utf8)

        #expect(SoxLog(url: temp.file("sox.json")).drops.map(\.receivedBy) == ["Bard"])
    }
}

struct SoxTableTests {
    private func drop(_ character: String, seal: String, ours: Bool, after seconds: TimeInterval) -> SoxDrop {
        SoxDrop(at: Date(timeIntervalSince1970: 1_790_000_000 + seconds), character: character, item: "Item \(character)", seal: seal, monster: "Mob", text: "t", ours: ours, seenBy: "alpha")
    }

    private var drops: [SoxDrop] {
        [
            drop("hunter", seal: "Star", ours: true, after: 0),
            drop("stranger", seal: "Moon", ours: false, after: 60),
            drop("bard", seal: "Sun", ours: true, after: 120),
        ]
    }

    @Test func listsTheNewestFirstAndMarksSunInBold() {
        let rows = SoxTable.rows(drops: drops, onlyMine: false, locale: english, timeZone: TimeZone(identifier: "UTC")!)

        #expect(rows.map { $0.cells[1] } == ["bard", "stranger", "hunter"])
        #expect(rows.map(\.bold) == [true, false, false])
        #expect(rows[0].cells.count == SoxTable.columns.count)
        #expect(Array(rows[0].cells[3...]) == ["Sun", "Mob", "alpha", ""])
        #expect(!rows[0].cells[0].isEmpty)
    }

    @Test func showsWentToRightAfterSeenBy() {
        #expect(SoxTable.columns.firstIndex(of: "Went to") == SoxTable.columns.firstIndex(of: "Seen by").map { $0 + 1 })
        var received = drop("hunter", seal: "Star", ours: true, after: 0)
        received.receivedBy = "bard"
        let rows = SoxTable.rows(drops: [received], onlyMine: false, locale: english)
        #expect(rows[0].cells.count == SoxTable.columns.count)
        #expect(Array(rows[0].cells[5...]) == ["alpha", "bard"])
    }

    @Test func hidesStarEntriesAndKeepsMoonAndSun() {
        let more = drops + [drop("cleric", seal: "Star", ours: false, after: 180)]

        #expect(SoxTable.rows(drops: more, onlyMine: false, locale: english).map { $0.cells[1] } == ["cleric", "bard", "stranger", "hunter"])
        #expect(SoxTable.rows(drops: more, onlyMine: false, hideStar: true, locale: english).map { $0.cells[1] } == ["bard", "stranger"])
        #expect(SoxTable.rows(drops: more, onlyMine: true, hideStar: true, locale: english).map { $0.cells[1] } == ["bard"])
    }

    @Test func leavesStarOutOfTheCountsWhenHidden() {
        let more = drops + [drop("cleric", seal: "Star", ours: false, after: 180)]

        #expect(SoxTable.summary(drops: more, onlyMine: false) == "Star 2 · Moon 1 · Sun 1 announced. The game announces SoX drops to the whole server.")
        #expect(SoxTable.summary(drops: more, onlyMine: false, hideStar: true) == "Moon 1 · Sun 1 announced. The game announces SoX drops to the whole server.")
        #expect(SoxTable.summary(drops: more, onlyMine: true, hideStar: true) == "Moon 0 · Sun 1 by your characters. The game announces SoX drops to the whole server.")
    }

    @Test func keepsRecordingStarDropsWhileHidden() {
        let temp = TemporaryDirectory()
        let log = SoxLog(url: temp.file("sox.json"))
        log.add("hunter has dropped Star Blade (Seal Of Star) from Mob", seenBy: "alpha", ours: ["hunter"])
        log.add("hunter has dropped Moon Blade (Seal Of Moon) from Mob", seenBy: "alpha", ours: ["hunter"])

        #expect(SoxTable.visible(log.drops, onlyMine: true, hideStar: true).count == 1)
        #expect(log.drops.map(\.seal) == ["Star", "Moon"])
        #expect(SoxLog(url: temp.file("sox.json")).drops.map(\.seal) == ["Star", "Moon"])
        #expect(SoxTable.visible(log.drops, onlyMine: true, hideStar: false).count == 2)
    }

    @Test func filtersToOurCharacters() {
        let rows = SoxTable.rows(drops: drops, onlyMine: true, locale: english)

        #expect(rows.map { $0.cells[1] } == ["bard", "hunter"])
    }

    @Test func summarisesWhatIsShown() {
        #expect(SoxTable.summary(drops: drops, onlyMine: true) == "Star 1 · Moon 0 · Sun 1 by your characters. The game announces SoX drops to the whole server.")
        #expect(SoxTable.summary(drops: drops, onlyMine: false) == "Star 1 · Moon 1 · Sun 1 announced. The game announces SoX drops to the whole server.")
        #expect(SoxTable.summary(drops: [], onlyMine: true) == "Star 0 · Moon 0 · Sun 0 by your characters. The game announces SoX drops to the whole server.")
    }
}

struct OurCharactersTests {
    @Test func joinsReportedAndSavedNamesWithoutBlanksOrCaseDuplicates() {
        let accounts = [
            Account(id: "aaaaaaaaaaaa", name: "a", character: "Hunter"),
            Account(id: "bbbbbbbbbbbb", name: "b", character: "  "),
            Account(id: "cccccccccccc", name: "c", character: "Saved"),
            Account(id: "dddddddddddd", name: "d"),
        ]

        let names = OurCharacters.names(reported: ["aaaaaaaaaaaa": "hunter", "bbbbbbbbbbbb": "", "eeeeeeeeeeee": "Other"], accounts: accounts)

        #expect(Set(names.map { $0.lowercased() }) == ["hunter", "saved", "other"])
        #expect(names.count == 3)
    }

    @Test func isEmptyWithNothingKnown() {
        #expect(OurCharacters.names(reported: [:], accounts: []).isEmpty)
    }
}

struct FooterTextTests {
    @Test func showsTheBotVersionOrADash() {
        #expect(FooterText.line(botVersion: "1.2.172") == "Bot 1.2.172")
        #expect(FooterText.line(botVersion: nil) == "Bot —")
    }

    @Test func leavesAPlaceForTheCacheText() {
        #expect(FooterText.line(botVersion: "1", cache: "shared cache 2 GB") == "Bot 1 · shared cache 2 GB")
    }
}

struct RealPayloadTests {
    private func plainContext(_ extra: String = "") throws -> JSContext {
        let source = try String(contentsOf: RepositoryPaths.sharedScripts.appendingPathComponent("drops.js"), encoding: .utf8)
        let context = JSContext()!
        context.exceptionHandler = { _, exception in context.setObject(exception?.toString() ?? "", forKeyedSubscript: "failure" as NSString) }
        context.evaluateScript(source + "\n" + extra)
        return context
    }

    @Test func feedsTheDropsTheRealReaderProducesThroughTheParserAndTheLog() throws {
        let context = try plainContext("""
        var reader = createDropReader();
        reader.gameplay({ chat: { lines: [{ sequence: 1, channel: 7, text: 'old has dropped Item (Seal Of Star) from Mob' }] }, notices: [{ sequence: 10, text: 'SEAL OF SUN: old has dropped Item from Mob', sunDrop: true }] });
        reader.take();
        reader.gameplay({ chat: { lines: [
          { sequence: 2, channel: 7, text: 'hunter has dropped Demon Polearm (Seal Of Star) from Wing Tribe Chaser' },
          { sequence: 3, channel: 7, text: 'a has dropped Blaze Diadem (Seal Of Moon) from Wing Tribe Chaser' },
          { sequence: 4, channel: 1, text: 'b has dropped Thing (Seal Of Star) from Mob' },
          { sequence: 5, channel: 7, text: 'c has dropped Plain Sword from Mob' },
        ] }, notices: [
          { sequence: 11, text: 'SEAL OF SUN: sorcerer has dropped Lynx Valor Phantom from Tiger Woman', sunDrop: true },
          { sequence: 12, text: 'bard has dropped Sun Blade (Seal Of Sun) from Tiger Woman', bannerOnly: true },
        ] });
        var message = JSON.stringify({ type: 'status', drops: reader.take() });
        """)
        #expect(context.objectForKeyedSubscript("failure").toString() == "undefined")
        let message = try #require(context.objectForKeyedSubscript("message").toString())

        let status = try #require(BotStatus.parse(message))
        #expect(status.drops.count == 4)
        let temp = TemporaryDirectory()
        let log = SoxLog(url: temp.file("sox.json"))
        for text in status.drops {
            log.add(text, seenBy: "alpha", ours: ["hunter", "bard"])
        }

        #expect(log.drops.map(\.character) == ["hunter", "a", "sorcerer", "bard"])
        #expect(log.drops.map(\.seal) == ["Star", "Moon", "Sun", "Sun"])
        #expect(log.drops.map(\.ours) == [true, false, false, true])
    }

    @Test func feedsThePickupNoticesTheRealReaderProducesThroughTheParserAndTheLog() throws {
        let context = try plainContext("""
        var reader = createDropReader();
        reader.gameplay({ social: { members: [{ name: 'Hunter' }, { name: 'Bard' }] }, notices: [{ sequence: 1, key: 'UIIT_MSG_STATE_GAIN_GOLD', value: 5 }] });
        reader.gameplay({ notices: [
          { sequence: 2, text: 'SEAL OF SUN: Hunter has dropped Sun Bow from Mob', sunDrop: true },
          { sequence: 3, key: 'UIIT_MSG_PARTYGET_ITEM_EXPENDABLE', arguments: ['Sun Bow', 1, 'Bard'], value: 1 },
          { sequence: 4, key: 'UIIT_MSG_STATE_GET_ITEM_EXPENDABLE', arguments: ['HP Potion', 3], value: 3 },
        ] });
        var message = JSON.stringify({ type: 'status', drops: reader.take(), received: reader.takeReceived() });
        """)
        #expect(context.objectForKeyedSubscript("failure").toString() == "undefined")
        let status = try #require(BotStatus.parse(context.objectForKeyedSubscript("message").toString()))
        #expect(status.received.map(\.item) == ["Sun Bow", "HP Potion"])
        let temp = TemporaryDirectory()
        let log = SoxLog(url: temp.file("sox.json"))
        for text in status.drops {
            log.add(text, seenBy: "alpha", ours: ["Hunter"])
        }
        for receipt in status.received {
            log.receive(receipt, ownCharacter: "Hunter")
        }

        #expect(log.drops.map(\.receivedBy) == ["Bard"])
    }

    @Test func readsTheSessionTheRealBridgeReports() throws {
        let (library, _) = try assembledScripts()
        let context = JSContext()!
        context.exceptionHandler = { _, exception in context.setObject(exception?.toString() ?? "", forKeyedSubscript: "failure" as NSString) }
        context.evaluateScript("""
        var window = this; window.top = window;
        var posted = []; var timers = [];
        var setInterval = callback => timers.push(callback); var setTimeout = callback => timers.push(callback);
        var performance = { now: () => 0 }; var navigator = {};
        var location = { origin: 'https://opensro.online', href: 'https://opensro.online/play' };
        var document = { readyState: 'complete', documentElement: { append: () => {} }, querySelector: () => null, createElement: () => ({ style: {}, setAttribute: () => {}, remove: () => {} }), addEventListener: () => {} };
        window.requestAnimationFrame = callback => 1; window.cancelAnimationFrame = () => {}; window.Worker = class {};
        window.SROLean = {
          version: '1.2.172',
          world: {
            phase: 'world', charName: 'hunter', inWorld: () => true, isDead: () => false,
            me: () => ({ hpPct: 73.4, mpPct: 86 }), pose: () => ({ regionId: 23918 }),
            items: () => [{ typeFlags: 0x09ec, quantity: 5 }, { typeFlags: 0x19ec, quantity: 3 }],
            gp: { progression: { level: 90, gold: '1685416273' } },
          },
          stats: { session: { ms: 4080000, kills: 288, deaths: 0, xp: '0', gold: '-175590000', sox: 2 }, xpKnown: true, goldKnown: true },
          hunt: { running: true }, town: { trip: false },
        };
        """)
        installPageScripts(try library.scripts(frameLimit: 60, userScripts: []), into: context)

        context.evaluateScript("timers.slice().forEach(callback => callback());")

        #expect(context.objectForKeyedSubscript("failure").toString() == "undefined")
        let status = try #require(BotStatus.parse(context.evaluateScript("posted[posted.length - 1]").toString()))
        #expect(status.character == "hunter")
        #expect(status.botVersion == "1.2.172")
        #expect(status.inWorld && status.hunting)
        #expect(status.session == SessionStats(milliseconds: 4_080_000, kills: 288, deaths: 0, experience: 0, gold: -175_590_000, sox: 2))
        #expect(status.returnScrolls == 5 && status.reverseScrolls == 3)
        #expect(status.gold == 1_685_416_273)
        #expect(status.level == 90 && status.region == 23918)
    }

    private func assembledScripts() throws -> (PageScriptLibrary, URL) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sro-scripts-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        for name in PageScriptLibrary.bridgeParts + [PageScriptLibrary.bridgePage] {
            try FileManager.default.copyItem(at: RepositoryPaths.sharedScripts.appendingPathComponent(name), to: temp.appendingPathComponent(name))
        }
        for name in [PageScriptLibrary.browserShim] {
            try FileManager.default.copyItem(at: RepositoryPaths.resources.appendingPathComponent(name), to: temp.appendingPathComponent(name))
        }
        return (PageScriptLibrary(directory: temp), temp)
    }
}
