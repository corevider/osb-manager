import AppKit
import OsbManagerCore

@MainActor
enum AppMenu {
    static let gameWindowItemTag = 900

    static func build(main: MainWindowController, app: AppDelegate, services: AppServices) -> NSMenu {
        let bar = NSMenu()
        bar.addItem(submenuItem(applicationMenu(app, language: TelemetryController.resolveLanguage(app.options))))
        bar.addItem(submenuItem(fileMenu(main)))
        bar.addItem(submenuItem(editMenu(app)))
        bar.addItem(submenuItem(accountsMenu(main)))
        bar.addItem(submenuItem(scriptsMenu(main)))
        bar.addItem(submenuItem(viewMenu(main)))
        bar.addItem(submenuItem(gameMenu(app)))
        let window = windowMenu(app)
        bar.addItem(submenuItem(window))
        NSApp.windowsMenu = nil
        return bar
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, key: String = "", modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        item.tag = tag
        return item
    }

    private static func applicationMenu(_ app: AppDelegate, language: ConsentLanguage) -> NSMenu {
        let interface = InterfaceTexts.texts(for: language)
        let menu = NSMenu(title: AppIdentity.name)
        menu.addItem(item("About \(AppIdentity.name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
        menu.addItem(.separator())
        menu.addItem(item(interface.privacyMenu, #selector(AppDelegate.showPrivacyWindow), target: app))
        menu.addItem(item(interface.reportMenu, #selector(AppDelegate.showReportWindow), target: app))
        menu.addItem(item(interface.unsentReports + "…", #selector(AppDelegate.showUnsentReportsWindow), target: app))
        menu.addItem(.separator())
        menu.addItem(item("Check for Updates Now…", #selector(UpdateController.checkNow), target: app.updates))
        menu.addItem(item("Check for Updates", #selector(UpdateController.toggleAutomaticChecks), target: app.updates))
        menu.addItem(.separator())
        menu.addItem(item("Hide \(AppIdentity.name)", #selector(NSApplication.hide(_:)), key: "h", target: NSApp))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], target: NSApp))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(AppIdentity.name)", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        return menu
    }

    private static func fileMenu(_ main: MainWindowController) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Open data folder", #selector(MainWindowController.openDataFolder), key: "o", target: main))
        menu.addItem(item("Clear shared asset cache…", #selector(MainWindowController.clearSharedCache), target: main))
        menu.addItem(.separator())
        menu.addItem(item("Close game window", #selector(MainWindowController.closeSelectedWindow), key: "w", target: main))
        return menu
    }

    private static func editMenu(_ app: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Edit")
        let action = #selector(AppDelegate.performEditAction(_:))
        menu.addItem(item("Undo", action, key: "z", target: app, tag: EditAction.undo.rawValue))
        menu.addItem(item("Redo", action, key: "Z", modifiers: [.command, .shift], target: app, tag: EditAction.redo.rawValue))
        menu.addItem(.separator())
        menu.addItem(item("Cut", action, key: "x", target: app, tag: EditAction.cut.rawValue))
        menu.addItem(item("Copy", action, key: "c", target: app, tag: EditAction.copy.rawValue))
        menu.addItem(item("Paste", action, key: "v", target: app, tag: EditAction.paste.rawValue))
        menu.addItem(item("Select All", action, key: "a", target: app, tag: EditAction.selectAll.rawValue))
        return menu
    }

    private static func accountsMenu(_ main: MainWindowController) -> NSMenu {
        let menu = NSMenu(title: "Accounts")
        let up = String(UnicodeScalar(NSUpArrowFunctionKey) ?? " ")
        let down = String(UnicodeScalar(NSDownArrowFunctionKey) ?? " ")
        menu.addItem(item("Add…", #selector(MainWindowController.addAccount), key: "n", target: main))
        menu.addItem(item("Remove…", #selector(MainWindowController.removeSelectedAccount), target: main))
        menu.addItem(item("Move up", #selector(MainWindowController.moveSelectedUp), key: up, modifiers: [.command, .option], target: main))
        menu.addItem(item("Move down", #selector(MainWindowController.moveSelectedDown), key: down, modifiers: [.command, .option], target: main))
        menu.addItem(.separator())
        menu.addItem(item("Start", #selector(MainWindowController.startSelectedAccount), key: "\r", target: main))
        menu.addItem(item("Start light", #selector(MainWindowController.startSelectedAccountLight), key: "\r", modifiers: [.command, .shift], target: main))
        menu.addItem(item("Start all", #selector(MainWindowController.startAllAccounts), target: main))
        menu.addItem(item("Start all light", #selector(MainWindowController.startAllAccountsLight), target: main))
        menu.addItem(.separator())
        menu.addItem(item("Close all", #selector(MainWindowController.closeAllWindows), target: main))
        return menu
    }

    private static func scriptsMenu(_ main: MainWindowController) -> NSMenu {
        let menu = NSMenu(title: "Scripts")
        menu.addItem(item("Add from file…", #selector(MainWindowController.addScriptFromFile), target: main))
        menu.addItem(item("Add from URL…", #selector(MainWindowController.addScriptFromUrl), target: main))
        menu.addItem(item("Update", #selector(MainWindowController.updateScripts), target: main))
        menu.addItem(item("Reload open game windows", #selector(MainWindowController.reloadGameWindows), key: "r", modifiers: [.command, .shift], target: main))
        return menu
    }

    private static func viewMenu(_ main: MainWindowController) -> NSMenu {
        let menu = NSMenu(title: "View")
        let limits = NSMenu(title: "Frame rate limit")
        for fps in AppSettings.frameLimits {
            limits.addItem(item(fps == 0 ? "No limit (monitor refresh)" : "\(fps) FPS", #selector(MainWindowController.chooseFrameLimit(_:)), target: main, tag: fps))
        }
        let limitItem = NSMenuItem(title: "Frame rate limit", action: nil, keyEquivalent: "")
        limitItem.submenu = limits
        menu.addItem(limitItem)
        menu.addItem(item("Share game files between accounts", #selector(MainWindowController.toggleShareGameFiles), target: main))
        menu.addItem(item("Restart a window when its renderer cannot start", #selector(MainWindowController.toggleRestartAfterRendererFailure), target: main))
        return menu
    }

    private static func gameMenu(_ app: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Game")
        menu.addItem(item("Reload", #selector(AppDelegate.reloadGame), key: "r", target: app))
        menu.addItem(item("Light mode", #selector(AppDelegate.toggleLight), key: "l", target: app))
        menu.addItem(item("Mute", #selector(AppDelegate.toggleMute), key: "m", modifiers: [.command, .shift], target: app))
        menu.addItem(item("Hide window", #selector(AppDelegate.toggleGameVisibility), key: "h", modifiers: [.command, .shift], target: app))
        return menu
    }

    private static func windowMenu(_ app: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.delegate = app
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item(AppIdentity.name, #selector(AppDelegate.showMainWindow), key: "0", target: app))
        return menu
    }
}
