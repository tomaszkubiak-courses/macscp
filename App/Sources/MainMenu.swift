import AppKit
import Sparkle

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        main.addItem(submenu("MacSCP", [
            item(String(localized: "About MacSCP"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            updateItem(),
            .separator(),
            item(String(localized: "Settings…"), #selector(AppDelegate.showPreferences(_:)), ","),
            .separator(),
            item(String(localized: "Hide MacSCP"), #selector(NSApplication.hide(_:)), "h"),
            item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(String(localized: "Quit MacSCP"), #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu(String(localized: "Session"), [
            item(String(localized: "New Session…"), #selector(AppDelegate.showSiteManager(_:)), "n"),
            item(String(localized: "Open in Terminal"), #selector(CommanderWindowController.openInTerminal(_:)), "t", [.command, .shift]),
            item(String(localized: "Edited Files…"), #selector(CommanderWindowController.showEditedFiles(_:)), "e", [.command, .shift]),
            item(String(localized: "Synchronize…"), #selector(CommanderWindowController.synchronize(_:)), "s", [.command, .shift]),
            .separator(),
            item(String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w"),
        ]))

        main.addItem(submenu(String(localized: "Edit"), [
            item(String(localized: "Undo"), Selector(("undo:")), "z"),
            item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"),
            item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"),
            item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"),
            item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"),
        ]))

        main.addItem(submenu(String(localized: "Files"), [
            item(String(localized: "Open"), #selector(FilePaneViewController.openSelection(_:)), String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))),
            item(String(localized: "Edit"), #selector(FilePaneViewController.editSelection(_:)), "e"),
            item(String(localized: "Edit With…"), #selector(FilePaneViewController.editSelectionWith(_:)), "e", [.command, .option]),
            .separator(),
            item(String(localized: "Copy to Other Pane…"), #selector(FilePaneViewController.transferSelection(_:)), "k"),
            item(String(localized: "Rename…"), #selector(FilePaneViewController.renameSelection(_:)), "r", [.command, .shift]),
            item(String(localized: "Move to Trash / Delete"), #selector(FilePaneViewController.deleteSelection(_:)), "\u{8}"),
            item(String(localized: "New Folder…"), #selector(FilePaneViewController.newFolder(_:)), "n", [.command, .shift]),
            .separator(),
            item(String(localized: "Get Info"), #selector(FilePaneViewController.getInfo(_:)), "i"),
            item(String(localized: "Quick Look"), #selector(FilePaneViewController.quickLook(_:)), "y"),
        ]))

        main.addItem(submenu(String(localized: "View"), [
            item(String(localized: "Show Hidden Files"), #selector(CommanderWindowController.toggleHiddenFiles(_:)), ".", [.command, .shift]),
            item(String(localized: "Show Queue"), #selector(CommanderWindowController.toggleQueue(_:)), "q", [.command, .option]),
            item(String(localized: "Refresh"), #selector(FilePaneViewController.refresh(_:)), "r"),
            .separator(),
            item(String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        main.addItem(submenu(String(localized: "Go"), [
            item(String(localized: "Back"), #selector(FilePaneViewController.goBack(_:)), "["),
            item(String(localized: "Forward"), #selector(FilePaneViewController.goForward(_:)), "]"),
            item(String(localized: "Enclosing Folder"), #selector(FilePaneViewController.goUp(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))),
            item(String(localized: "Home"), #selector(FilePaneViewController.goHome(_:)), "h", [.command, .shift]),
            item(String(localized: "Go to Folder…"), #selector(FilePaneViewController.goToFolder(_:)), "g", [.command, .shift]),
            .separator(),
            item(String(localized: "Switch Pane"), #selector(CommanderWindowController.switchPane(_:)), "\t", [.control]),
        ]))

        let window = submenu(String(localized: "Window"), [
            item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = window.submenu
        main.addItem(window)

        let help = submenu(String(localized: "Help"), [])
        NSApp.helpMenu = help.submenu
        main.addItem(help)
        return main
    }

    private static func updateItem() -> NSMenuItem {
        let i = NSMenuItem(title: String(localized: "Check for Updates…"),
                           action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        i.target = AppDelegate.shared.updater
        return i
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }
}
