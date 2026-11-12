import Foundation
import Testing
@testable import OsbManagerCore

struct AccountMenuTests {
    private let account = Account(id: "a1b2c3d4e5f6", name: "First")
    private let other = Account(id: "0a0b0c0d0e0f", name: "Second")

    private func texts(_ items: [AccountMenuItem]) -> [String] {
        items.map(\.text)
    }

    @Test func aClosedAccountCanStartToggleMoveAndBeRemoved() {
        let items = AccountMenu.forAccount(account, state: .closed)

        #expect(texts(items) == ["Start", "Start light", "Toggle light mode", "Move up", "Move down", "Remove…"])
        #expect(items.allSatisfy { $0.enabled })
    }

    @Test func aQueuedAccountCanCancelItsStartFirst() {
        let items = AccountMenu.forAccount(account, state: .queued)

        #expect(texts(items) == ["Cancel start", "Start", "Start light", "Toggle light mode", "Move up", "Move down", "Remove…"])
        #expect(items.first?.action == .cancelStart)
        #expect(items.allSatisfy { $0.enabled })
    }

    @Test func anOpenAccountCanShowReloadAndClose() {
        let items = AccountMenu.forAccount(account, state: .open)

        #expect(texts(items) == ["Show window", "Reload window", "Close", "Toggle light mode", "Move up", "Move down", "Remove…"])
        #expect(items.map(\.action) == [.showWindow, .reloadWindow, .close, .toggleLight, .moveUp, .moveDown, .remove])
    }

    @Test func removingAnOpenAccountStaysEnabledBecauseTheAppClosesItsWindowFirst() throws {
        let remove = try #require(AccountMenu.forAccount(account, state: .open).last)

        #expect(remove.action == .remove)
        #expect(remove.enabled)
    }

    @Test func theRootMenuHasTheAccountsMenuActions() {
        let items = AccountMenu.forRoot()

        #expect(texts(items) == ["Add…", "Start all", "Start all light", "Close all"])
        #expect(items.map(\.action) == [.add, .startAll, .startAllLight, .closeAll])
        #expect(items.allSatisfy { $0.target == nil && $0.enabled })
    }

    @Test(arguments: [AccountMenuState.closed, .queued, .open])
    func everyItemNamesItsOwnAccount(state: AccountMenuState) {
        let items = AccountMenu.forAccount(other, state: state)

        #expect(items.allSatisfy { $0.target == other })
        #expect(AccountMenu.forAccount(account, state: state).allSatisfy { $0.target == account })
    }

    @Test(arguments: [AccountMenuState.closed, .queued, .open])
    func theSameStateGivesTheSameItems(state: AccountMenuState) {
        #expect(AccountMenu.forAccount(account, state: state) == AccountMenu.forAccount(account, state: state))
    }

    @Test func separatorsGroupTheItems() {
        let items = AccountMenu.forAccount(account, state: .open)

        #expect(items.filter { $0.separatorBefore }.map(\.text) == ["Toggle light mode", "Move up", "Remove…"])
        #expect(items.first?.separatorBefore == false)
        #expect(AccountMenu.forRoot().filter { $0.separatorBefore }.map(\.text) == ["Start all", "Close all"])
    }

    @Test func theNamesMatchTheAccountsMenu() {
        #expect(AccountMenu.add == "Add…")
        #expect(AccountMenu.remove == "Remove…")
        #expect(AccountMenu.moveUp == "Move up")
        #expect(AccountMenu.moveDown == "Move down")
        #expect(AccountMenu.start == "Start")
        #expect(AccountMenu.startLight == "Start light")
        #expect(AccountMenu.startAll == "Start all")
        #expect(AccountMenu.startAllLight == "Start all light")
        #expect(AccountMenu.closeAll == "Close all")
    }

    @Test func aQueuedAccountIsKnownToTheStartQueueSoTheMenuCanCancelIt() {
        let queue = StartQueue(gap: 15)
        queue.add(account.id, light: false)

        #expect(queue.contains(account.id))
        #expect(queue.remove(account.id))
        #expect(!queue.contains(account.id))
        #expect(!queue.remove(account.id))
    }
}
