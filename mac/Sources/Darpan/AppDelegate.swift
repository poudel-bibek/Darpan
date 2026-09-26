import AppKit
import DarpanCore

/// App lifecycle: the connect window, at most one session at a time, the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var connectWindow: ConnectWindowController!
    private var session: Session?
    private var resolutionMenu: NSMenu?
    private var terminating = false

    func applicationWillFinishLaunching(_ n: Notification) {
        // Our own View → Enter Full Screen item uses ⌃⌥⌘F; don't let AppKit add another.
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        NSWindow.allowsAutomaticWindowTabbing = false
        let menus = MainMenu.build()
        NSApp.mainMenu = menus.main
        menus.resolution.delegate = self
        resolutionMenu = menus.resolution
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if Settings.shared.network == .builtIn && Tailnet.hasState { Tailnet.shared.start() }
        connectWindow = ConnectWindowController()
        connectWindow.model.handler = self
        connectWindow.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake(_:)),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        connectWindow.model.autoConnect(environment: ProcessInfo.processInfo.environment)
        Updater.shared.start()
        #if DEBUG
        DebugHooks.install(self)
        if ProcessInfo.processInfo.environment["DARPAN_DEBUG_FILES_WINDOW"] != nil {   // the Files window alone, for screenshots
            debugFiles = FilesWindowController(title: "Files")
            debugFiles?.showWindow(nil)
        }
        #endif
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let s = session, s.isConnected { s.window.makeKeyAndOrderFront(nil) } else { connectWindow.showWindow(nil) }
        }
        return true
    }

    func applicationWillTerminate(_ n: Notification) {
        Tailnet.shared.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let s = session else { return .terminateNow }
        // Say goodbye properly: the host ends the session (and restores its resolution) at once.
        terminating = true
        s.end()
        // A run-loop timer, not a main-queue block: terminate() may have been called from inside a
        // main-queue block, and the main queue doesn't run another block until that one returns.
        let t = Timer(timeInterval: 0.3, repeats: false) { _ in NSApp.reply(toApplicationShouldTerminate: true) }
        RunLoop.main.add(t, forMode: .common)
        return .terminateLater
    }

    #if DEBUG
    private var debugFiles: FilesWindowController?
    var debugSession: Session? { session }
    var debugConnectModel: ConnectModel { connectWindow.model }
    #endif

    @objc private func didWake(_ n: Notification) {
        session?.client.wake()
    }

    @objc func newConnection(_ sender: Any?) {
        connectWindow.showWindow(nil)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        if case .available = Updater.shared.state { Updater.shared.install() } else { Updater.shared.check(manual: true) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(checkForUpdates(_:)) else { return true }
        // An update found while a session hides the connect window is offered here too.
        switch Updater.shared.state {
        case .available(let m): item.title = "Install Darpan \(m.version) and Relaunch"
        case .installing: item.title = "Updating…"; return false
        default: item.title = "Check for Updates…"
        }
        return true
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: DarpanVersion.string,
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
            .credits: NSAttributedString(string: "Your Linux desktop on this Mac, over Tailscale.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                      .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }
}

extension AppDelegate: ConnectHandler {
    func connect(to address: HostAddress, proxy: SOCKSProxy?, password: String?, saved: SavedKey?, remember: Bool?) {
        let old = session
        session = nil
        old?.end()
        let s = Session(address: address, proxy: proxy, remember: remember, owner: self)
        session = s
        s.start(password: password, saved: saved)
    }

    func cancelConnect() {
        session?.end()
    }
}

extension AppDelegate: SessionOwner {
    func sessionDidConnect(_ s: Session) {
        guard s === session else { return }
        Settings.shared.noteHost(s.address.origin)
        connectWindow.model.connected()
        connectWindow.window?.orderOut(nil)
    }

    func sessionWaitingForHost(_ s: Session) {
        guard s === session else { return }
        connectWindow.model.hostStarting(s.address.shortName)
    }

    func sessionDidEnd(_ s: Session, failure: Client.Failure?) {
        guard s === session else { return }
        session = nil
        guard !terminating else { return }
        connectWindow.model.ended(failure, wasConnected: s.wasConnected)
        connectWindow.showWindow(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === resolutionMenu else { return }
        if let s = session, s.isConnected {
            s.fillResolutionMenu(menu)
        } else {
            menu.removeAllItems()
            menu.addItem(withTitle: "Not connected", action: nil, keyEquivalent: "")
        }
    }
}
