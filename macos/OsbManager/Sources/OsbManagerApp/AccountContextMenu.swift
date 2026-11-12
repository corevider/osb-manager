import AppKit
import OsbManagerCore

@MainActor
enum AccountContextMenu {
    static func build(_ items: [AccountMenuItem], target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in items {
            if entry.separatorBefore, !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: entry.text, action: action, keyEquivalent: "")
            item.target = target
            item.isEnabled = entry.enabled
            item.representedObject = entry
            menu.addItem(item)
        }
        return menu
    }
}
