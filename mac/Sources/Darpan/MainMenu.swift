import AppKit
import DarpanCore

/// The menu bar. Viewer commands have no target: they reach the session through the viewer
/// window's responder chain (the session is the window's delegate), so they're disabled when
/// there is no session. ⌃⌥⌘D/F/⎋ work even while every other key goes to the remote.
enum MainMenu {
    static func build() -> (main: NSMenu, resolution: NSMenu) {
        let main = NSMenu()
        let name = AppInfo.name

        let app = submenu(main, name)
        app.addItem(item("About \(name)", #selector(AppDelegate.showAbout(_:))))
        app.addItem(item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:))))   // retitled by AppDelegate
        app.addItem(.separator())
        let services = NSMenu()
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"))

        let edit = submenu(main, "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Delete", #selector(NSText.delete(_:))))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))

        let view = submenu(main, "View")
        view.addItem(item("Fit to Window", #selector(Session.setFitScale(_:))))
        view.addItem(item("Actual Size", #selector(Session.setActualScale(_:))))
        view.addItem(.separator())
        view.addItem(item("Show Stats", #selector(Session.toggleStats(_:))))
        view.addItem(item("Play Sound", #selector(Session.toggleSound(_:))))
        view.addItem(.separator())
        view.addItem(item("Release Keyboard", #selector(Session.toggleKeyboardCapture(_:)), "\u{1b}", [.control, .option, .command]))
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.control, .option, .command]))

        let conn = submenu(main, "Connection")
        conn.addItem(item("New Connection…", #selector(AppDelegate.newConnection(_:)), "n"))
        conn.addItem(.separator())
        let resolution = NSMenu(title: "Resolution")
        conn.addItem(withTitle: "Resolution", action: nil, keyEquivalent: "").submenu = resolution
        let quality = NSMenu(title: "Quality")
        for q in Settings.qualities {
            let i = item(q.kbps == 0 ? "Auto" : "\(q.name) (\(q.kbps / 1000) Mbps)", #selector(Session.chooseQuality(_:)))
            i.tag = q.kbps
            quality.addItem(i)
        }
        conn.addItem(withTitle: "Quality", action: nil, keyEquivalent: "").submenu = quality
        let rates = NSMenu(title: "Frame Rate")
        for f in Settings.frameRates {
            let i = item("\(f) fps", #selector(Session.chooseFrameRate(_:)))
            i.tag = f
            rates.addItem(i)
        }
        conn.addItem(withTitle: "Frame Rate", action: nil, keyEquivalent: "").submenu = rates
        conn.addItem(.separator())
        let keys = NSMenu(title: "Send Keys")
        for c in ViewerModel.combos {
            let i = item(c.name, #selector(Session.sendKeyCombo(_:)))
            i.representedObject = c.codes
            keys.addItem(i)
        }
        conn.addItem(withTitle: "Send Keys", action: nil, keyEquivalent: "").submenu = keys
        let command = NSMenu(title: "⌘ Command Sends")
        for (tag, title) in ["Ctrl", "Super"].enumerated() {
            let i = item(title, #selector(Session.chooseCommandKey(_:)))
            i.tag = tag
            command.addItem(i)
        }
        conn.addItem(withTitle: "⌘ Command Sends", action: nil, keyEquivalent: "").submenu = command
        conn.addItem(item("Send System Shortcuts (⌘Tab, ⌘Space…)", #selector(Session.toggleSystemShortcuts(_:))))
        conn.addItem(.separator())
        conn.addItem(item("Send Clipboard to Remote", #selector(Session.sendClipboardToRemote(_:))))
        conn.addItem(item("Type Clipboard on Remote", #selector(Session.typeClipboard(_:))))
        conn.addItem(item("Copy Remote Clipboard", #selector(Session.copyRemoteClipboard(_:))))
        conn.addItem(item("Send Files…", #selector(Session.sendFiles(_:))))
        conn.addItem(.separator())
        conn.addItem(item("Disconnect", #selector(Session.disconnect(_:)), "d", [.control, .option, .command]))

        let window = submenu(main, "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window

        NSApp.helpMenu = submenu(main, "Help")

        return (main, resolution)
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let m = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = m
        return m
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { i.keyEquivalentModifierMask = mods }
        return i
    }
}
