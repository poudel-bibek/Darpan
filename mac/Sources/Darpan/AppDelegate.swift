import AppKit
import DarpanCore

/// App lifecycle: the connect window, which stays (any computer in it connects, each in a window of
/// its own), the sessions, the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var connectWindow: ConnectWindowController!
    /// Every computer connected or connecting, each in its own window.
    private var sessions: [Session] = []
    /// The one the connect window is connecting: its progress and failure show there.
    private weak var pending: Session?
    /// The session whose window was in front last: only its sound plays.
    private weak var front: Session?
    /// A computer that failed while the connect window was busy with another: told once that's done.
    private var missed: (origin: String, title: String, failure: Client.Failure)?
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
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(willSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(didWake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameMain(_:)),
                                               name: NSWindow.didBecomeMainNotification, object: nil)
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
            if let s = front ?? sessions.last, s.isConnected { s.window.makeKeyAndOrderFront(nil) } else { connectWindow.showWindow(nil) }
        }
        return true
    }

    func applicationWillTerminate(_ n: Notification) {
        Tailnet.shared.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !sessions.isEmpty else { return .terminateNow }
        // Say goodbye properly: each host ends its session (and restores its resolution) at once.
        terminating = true
        for s in sessions { s.end() }
        // A run-loop timer, not a main-queue block: terminate() may have been called from inside a
        // main-queue block, and the main queue doesn't run another block until that one returns.
        let t = Timer(timeInterval: 0.3, repeats: false) { _ in NSApp.reply(toApplicationShouldTerminate: true) }
        RunLoop.main.add(t, forMode: .common)
        return .terminateLater
    }

    #if DEBUG
    private var debugFiles: FilesWindowController?
    var debugSession: Session? { front ?? sessions.last }
    var debugConnectModel: ConnectModel { connectWindow.model }
    #endif

    /// macOS waits for this handler, not for what it starts: the goodbyes go out before it returns
    /// (half a second at most, for all of them), so each host ends its session now rather than after 30 s.
    @objc private func willSleep(_ n: Notification) {
        let sent = DispatchGroup()
        for s in sessions {
            sent.enter()
            s.client.sleep { sent.leave() }
        }
        _ = sent.wait(timeout: .now() + 0.5)
    }

    /// A real wake: the system with its display on, or the screens coming on. Not a dark wake (the
    /// display stays off), so a sleeping Mac doesn't connect for a few seconds every 15 minutes.
    @objc private func didWake(_ n: Notification) {
        if n.name == NSWorkspace.didWakeNotification && CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return }
        for s in sessions { s.client.wake() }
    }

    /// The window in front decides whose sound plays.
    @objc private func windowBecameMain(_ n: Notification) {
        guard let w = n.object as? NSWindow, let s = sessions.first(where: { $0.window === w }) else { return }
        front = s
        for x in sessions { x.playsSound = x === s }
    }

    /// The session whose window is in front, for the menus.
    private var keySession: Session? {
        sessions.first { $0.window.isKeyWindow } ?? sessions.first { $0.window.isMainWindow } ?? front
    }

    /// The computers with a window of their own, connected or reconnecting (their rows bring it forward).
    private func updateConnected() {
        connectWindow.model.connectedOrigins = Set(sessions.filter(\.wasConnected).map(\.address.origin))
    }

    /// A failure missed while another computer was connecting, now that the connect window is free.
    private func tellMissed() {
        guard let m = missed else { return }
        missed = nil
        connectWindow.model.address = m.origin                // a password prompt is for that computer
        connectWindow.model.ended(m.failure, wasConnected: true, name: m.title)
        connectWindow.showWindow(nil)
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
        if let open = sessions.first(where: { $0.address.origin == address.origin }) {
            // Already open: its window (connected or reconnecting), not a second connection.
            if open.wasConnected {
                connectWindow.model.connected()
                open.window.makeKeyAndOrderFront(nil)
            } else {
                pending = open                               // still signing in: the connect window follows it
            }
            return
        }
        let s = Session(address: address, proxy: proxy, remember: remember, owner: self)
        s.playsSound = sessions.isEmpty                      // the others' sound stops when its window comes to the front
        sessions.append(s)
        pending = s
        s.start(password: password, saved: saved)
    }

    func cancelConnect() {
        pending?.end()
    }

    func show(_ origin: String) {
        guard let s = sessions.first(where: { $0.address.origin == origin && $0.wasConnected }) else { return }
        s.window.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: SessionOwner {
    func sessionDidConnect(_ s: Session) {
        Settings.shared.noteHost(s.address.origin)
        updateConnected()
        // The list stays, behind the new window: another computer connects from it too.
        if s === pending {
            pending = nil
            connectWindow.model.connected()
            tellMissed()
        }
    }

    func sessionWaitingForHost(_ s: Session) {
        guard s === pending else { return }
        connectWindow.model.hostStarting(Settings.shared.title(s.address.origin, original: s.address.shortName))
    }

    func sessionDidEnd(_ s: Session, failure: Client.Failure?) {
        sessions.removeAll { $0 === s }
        guard !terminating else { return }
        updateConnected()
        if front == nil || front === s, let next = sessions.last {   // the sound goes to one still open
            front = next
            next.playsSound = true
        }
        // What happened shows in the connect window; while it's busy connecting another computer, a
        // failure waits until that's done.
        guard pending == nil || s === pending else {
            if let failure { missed = (s.address.origin, s.window.title, failure) }
            return
        }
        pending = nil
        connectWindow.model.address = s.address.origin           // a password prompt is for this computer
        connectWindow.model.ended(failure, wasConnected: s.wasConnected,
                                  name: sessions.isEmpty ? nil : s.window.title)
        if failure != nil || sessions.isEmpty { connectWindow.showWindow(nil) }
        if failure != nil { missed = nil } else { tellMissed() }  // (two failures at once: the window shows this one)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === resolutionMenu else { return }
        if let s = keySession, s.isConnected {
            s.fillResolutionMenu(menu)
        } else {
            menu.removeAllItems()
            menu.addItem(withTitle: "Not connected", action: nil, keyEquivalent: "")
        }
    }
}
