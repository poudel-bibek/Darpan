import AppKit
import DarpanCore

/// App lifecycle: the connect window, at most one session at a time, the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
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
        #if DEBUG
        DebugHooks.install(self)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    #if DEBUG
    var debugSession: Session? { session }
    var debugConnectModel: ConnectModel { connectWindow.model }
    #endif

    @objc private func didWake(_ n: Notification) {
        session?.client.wake()
    }

    @objc func newConnection(_ sender: Any?) {
        connectWindow.showWindow(nil)
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
    func connect(to address: HostAddress, proxy: SOCKSProxy?, password: String?, saved: SavedKey?, remember: Bool) {
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
