import Foundation
import Testing
@testable import OsbManagerCore

struct AccountStoreTests {
    @Test func addsRenamesRemovesAndPersists() throws {
        let temp = TemporaryDirectory()
        let url = temp.file("accounts.json")
        let store = try AccountStore.load(from: url)
        let first = try store.add(name: "  hunter ")
        let second = try store.add(name: "healer")
        try store.rename(id: second.id, to: "apocalypse")
        try store.update(id: first.id) { $0.startLight = true }
        try store.remove(id: second.id)

        let reloaded = try AccountStore.load(from: url)

        #expect(reloaded.accounts.count == 1)
        let account = try #require(reloaded.accounts.first)
        #expect(account.name == "hunter")
        #expect(account.startLight)
        #expect(account.id == first.id)
        #expect(account.dataStoreId == first.dataStoreId)
    }

    @Test func movesAccountsUpAndDownAndKeepsTheOrder() throws {
        let temp = TemporaryDirectory()
        let url = temp.file("accounts.json")
        let store = try AccountStore.load(from: url)
        let a = try store.add(name: "a")
        let b = try store.add(name: "b")
        let c = try store.add(name: "c")

        #expect(try store.move(id: c.id, by: -1))
        #expect(try !store.move(id: a.id, by: -1))
        #expect(try !store.move(id: b.id, by: 1))
        #expect(try !store.move(id: "000000000000", by: 1))
        #expect(try store.move(id: a.id, by: 5))

        #expect(try AccountStore.load(from: url).accounts.map(\.name) == ["c", "b", "a"])
    }

    @Test func givesEveryAccountItsOwnDataStore() throws {
        let temp = TemporaryDirectory()
        let store = try AccountStore.load(from: temp.file("accounts.json"))

        let stores = try (0..<20).map { try store.add(name: "acc\($0)").dataStoreId }

        #expect(Set(stores).count == 20)
        #expect(Set(store.accounts.map(\.id)).count == 20)
    }

    @Test(arguments: [
        ("", "Enter a name."),
        ("   ", "Enter a name."),
        ("HUNTER", "Another account already uses this name."),
        ("tab\there", "Remove control characters from the name."),
        (String(repeating: "x", count: 41), "Use at most 40 characters."),
    ])
    func explainsInvalidNames(name: String, problem: String) {
        let existing = [Account(id: "000000000000", name: "hunter")]

        #expect(AccountStore.nameProblem(name, existing: existing, excluding: nil) == problem)
    }

    @Test func allowsKeepingTheSameNameWhenRenaming() {
        let me = Account(id: "000000000000", name: "hunter")

        #expect(AccountStore.nameProblem("Hunter", existing: [me], excluding: me.id) == nil)
    }

    @Test func refusesInvalidNamesWhenAddingAndRenaming() throws {
        let temp = TemporaryDirectory()
        let store = try AccountStore.load(from: temp.file("accounts.json"))
        let one = try store.add(name: "one")

        #expect(throws: AccountError.self) { try store.add(name: "ONE") }
        #expect(throws: AccountError.self) { try store.rename(id: one.id, to: "") }
        #expect(store.accounts.map(\.name) == ["one"])
    }

    @Test func dropsInvalidAndDuplicateEntriesOnLoad() throws {
        let temp = TemporaryDirectory()
        let url = temp.file("accounts.json")
        try """
        [
          {"id":"aaaaaaaaaaaa","name":"one","dataStoreId":"11111111-1111-1111-1111-111111111111"},
          {"id":"../x","name":"bad id"},
          {"id":"bbbbbbbbbbbb","name":"ONE"},
          {"id":"cccccccccccc","name":""},
          {"id":"dddddddddddd","name":"two","dataStoreId":"not a uuid"},
          {"id":"eeeeeeeeeeee","name":"three","dataStoreId":"11111111-1111-1111-1111-111111111111"},
          {"id":"aaaaaaaaaaaa","name":"again"},
          "garbage",
          {"id":"ffffffffffff","name":"four"}
        ]
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = try AccountStore.load(from: url)

        #expect(store.accounts.map(\.name) == ["one", "four"])
    }

    @Test func fillsMissingFieldsWithDefaults() throws {
        let temp = TemporaryDirectory()
        let url = temp.file("accounts.json")
        try #"[{"id":"aaaaaaaaaaaa","name":"one"}]"#.write(to: url, atomically: true, encoding: .utf8)

        let account = try #require(try AccountStore.load(from: url).accounts.first)

        #expect(!account.startLight)
        #expect(account.window == nil)
        #expect(account.loginId.isEmpty && account.server.isEmpty && account.character.isEmpty && !account.autoLogin)
    }

    @Test func refusesAFileThatIsNotJson() throws {
        let temp = TemporaryDirectory()
        let url = temp.file("accounts.json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) { try AccountStore.load(from: url) }
    }

    @Test func usesTheWindowsFieldNames() throws {
        let temp = TemporaryDirectory()
        let url = temp.file("accounts.json")
        let store = try AccountStore.load(from: url)
        let account = try store.add(name: "hunter")
        try store.update(id: account.id) {
            $0.startLight = true
            $0.window = WindowPlacement(x: 10, y: 20, width: 1280, height: 800, maximized: false)
        }

        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let entry = try #require(object.first)

        #expect(Set(entry.keys).isSuperset(of: ["id", "name", "startLight", "window", "dataStoreId"]))
        let window = try #require(entry["window"] as? [String: Any])
        #expect(Set(window.keys) == ["x", "y", "width", "height", "maximized"])
    }
}
