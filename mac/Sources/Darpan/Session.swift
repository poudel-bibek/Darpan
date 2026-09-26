import AppKit
import Combine
import DarpanCore
import SwiftUI

protocol SessionOwner: AnyObject {
    func sessionDidConnect(_ session: Session)
    /// The session is over (window closed). `failure` nil: the user disconnected.
    func sessionDidEnd(_ session: Session, failure: Client.Failure?)
}

/// One connection to a remote computer: the client, its viewer window and everything in it.
/// The window appears once signed in; until then the connect window shows progress.
final class Session: NSObject {
    let address: HostAddress
    let window: NSWindow
    private(set) var client: Client!
    private(set) var wasConnected = false

    private weak var owner: SessionOwner?
    /// nil: leave the Keychain as it is (test runs with DARPAN_PASSWORD).
    private let remember: Bool?
    private let settings = Settings.shared
    private let content = ViewerContentView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    private var video: VideoView { content.video }
    private var keyboard: KeyboardCapture!
    private var clipboard: ClipboardSync!
    private let model = ViewerModel()
    private let player = AudioPlayer()
    private var popover: NSPopover?
    private var bag = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var ticker: Timer?
    private var ticks = 0
    private var ended = false
    private var sized = false
    private var uploadToasts: [String: ToastStack.Toast] = [:]
    private let logStats = ProcessInfo.processInfo.environment["DARPAN_LOG_STATS"] != nil

    init(address: HostAddress, proxy: SOCKSProxy?, remember: Bool?, owner: SessionOwner) {
        self.address = address
        self.remember = remember
        self.owner = owner
        window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: true)
        super.init()
        client = Client(address: address, sink: video, proxy: proxy)
        client.delegate = self
        keyboard = KeyboardCapture(video: video)
        clipboard = ClipboardSync { [weak self] text in self?.client.send(Msg.clip(text)) }
        setUpWindow()
        wire()
    }

    func start(password: String?, saved: SavedKey?) {
        client.setVideoActive(true)          // the window appears with the sign-in: ask for video right away
        client.connect(password: password, saved: saved)
    }

    /// User-initiated: disconnect and close the window now (the client says goodbye on its own queue).
    func end() {
        guard !ended else { return }
        releaseInput()
        client.disconnect()
        finish(nil)
    }

    var isConnected: Bool { client.state == .connected }

    #if DEBUG
    var debugContent: ViewerContentView { content }
    var debugModel: ViewerModel { model }
    func debugToolbar(_ item: ToolbarView.Item) {
        content.toolbar.expand()
        if let b = content.toolbar.button(item) { toolbarAction(item, b) }
    }
    #endif

    // MARK: - setup

    private func setUpWindow() {
        window.title = address.shortName
        window.contentView = content
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.minSize = NSSize(width: 480, height: 300)
        window.initialFirstResponder = video
        window.delegate = self
    }

    private func wire() {
        video.delegate = self
        video.dropHighlight = { [weak self] on in self?.content.drop.isHidden = !on }
        keyboard.send = { [weak self] m in self?.client.send(m) }
        keyboard.beforePaste = { [weak self] in
            guard let self else { return true }
            guard self.clipboard.beforePaste() else {
                self.content.toasts.show("The clipboard is too large to paste on the remote computer (1 MB at most).", error: true)
                return false
            }
            return true
        }

        let bar = content.toolbar
        bar.onAction = { [weak self] item, button in self?.toolbarAction(item, button) }
        bar.onMove = { [weak self] x in self?.content.toolbarX = x }
        bar.onMoveEnded = { [weak self] in
            guard let self else { return }
            self.settings.pillX = Double(self.content.toolbarX)
        }
        content.toolbarX = CGFloat(settings.pillX)

        model.setResolution = { [weak self] mode in
            guard let self else { return }
            self.client.send(mode.map { Msg.res(w: $0.w, h: $0.h) } ?? Msg.resNative)
            self.content.toasts.show("Changing resolution…", ttl: 1.5)
        }
        model.sendCombo = { [weak self] codes in self?.keyboard.combo(codes) }
        model.copyRemote = { [weak self] in self?.copyRemoteClipboard(nil) }
        model.setRemoteClipboard = { [weak self] text in
            self?.clipboard.setRemote(text)
            self?.content.toasts.show("Remote clipboard set")
        }
        model.type = { [weak self] text in
            self?.type(text)
            self?.popover?.close()
        }

        settings.$scale.sink { [weak self] in self?.video.scaleMode = $0 }.store(in: &bag)
        settings.$fps.combineLatest(settings.$quality)
            .sink { [weak self] fps, kbps in self?.client.setVideo(fps: fps, bitrate: kbps) }.store(in: &bag)
        settings.$command.sink { [weak self] in self?.keyboard.translator.command = $0 }.store(in: &bag)
        settings.$scrollSpeed.combineLatest(settings.$invertScroll).sink { [weak self] speed, invert in
            self?.video.wheel.speed = speed
            self?.video.wheel.invert = invert
        }.store(in: &bag)
        settings.$sound.sink { [weak self] on in
            guard let self else { return }
            self.content.toolbar.soundOn = on
            self.client.setAudio(on, sink: self.player)
            if !on { self.player.stop() }
        }.store(in: &bag)
        settings.$showStats.sink { [weak self] on in
            guard let self else { return }
            self.content.stats.isHidden = !on
            self.content.toolbar.statsOn = on
            if on { _ = self.client.takeStats() }        // start a fresh interval
            DispatchQueue.main.async { self.updateTicker() }
        }.store(in: &bag)
        settings.$captureSystemKeys.dropFirst().sink { [weak self] on in
            if on && !KeyboardCapture.accessibilityTrusted { KeyboardCapture.requestAccessibility() }
            DispatchQueue.main.async { self?.updateTap() }
        }.store(in: &bag)

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            guard let self, self.isConnected else { return }
            self.clipboard.poll()                        // something may have been copied in another app
            self.model.accessibilityTrusted = KeyboardCapture.accessibilityTrusted
            self.updateTap()
        })
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
            [weak self] _ in self?.releaseInput()
        })
    }

    // MARK: - window

    private func showWindow() {
        if !sized { sizeWindow(for: nil) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(video)
        NSApp.activate(ignoringOtherApps: true)
        let shown = UserDefaults.standard.integer(forKey: "shortcutHintShown")
        if shown < 3 {
            UserDefaults.standard.set(shown + 1, forKey: "shortcutHintShown")
            content.toasts.show("⌘ shortcuts go to the remote computer. ⌃⌥⌘D disconnects, ⌃⌥⌘⎋ releases the keyboard.", ttl: 7)
        }
    }

    /// One remote pixel per device pixel if that fits on screen, otherwise as large as fits.
    private func sizeWindow(for mode: DisplayMode?) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        sized = true
        let scale = screen.backingScaleFactor
        let area = screen.visibleFrame
        let chrome = window.frameRect(forContentRect: .zero).size
        let m = mode ?? DisplayMode(Int(area.width * scale * 0.8), Int(area.height * scale * 0.8))
        var w = CGFloat(m.w) / scale, h = CGFloat(m.h) / scale
        let k = min(1, (area.width * 0.94 - chrome.width) / w, (area.height * 0.94 - chrome.height) / h)
        w = (w * k).rounded()
        h = (h * k).rounded()
        window.setContentSize(NSSize(width: max(window.minSize.width, w), height: max(window.minSize.height, h)))
        window.center()
    }

    /// Everything the host believes is pressed is released there too.
    private func releaseInput() {
        let keys = keyboard.reset()
        let buttons = video.releaseButtons()
        if keys || buttons { client.send(Msg.rel) }
    }

    private func finish(_ failure: Client.Failure?, closeWindow: Bool = true) {
        guard !ended else { return }
        ended = true
        ticker?.invalidate()
        ticker = nil
        keyboard.invalidate()
        bag.removeAll()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        popover?.close()
        client.setAudio(false, sink: nil)
        player.stop()
        video.clear()
        window.delegate = nil
        if closeWindow { window.close() }
        owner?.sessionDidEnd(self, failure: failure)
    }

    /// Stats, the quality dot and the clipboard poll: twice a second, only while connected and
    /// the window is visible.
    private func updateTicker() {
        let want = !ended && isConnected && window.occlusionState.contains(.visible)
        if want, ticker == nil {
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        } else if !want, let t = ticker {
            t.invalidate()
            ticker = nil
        }
    }

    private func tick() {
        ticks += 1
        content.toolbar.quality = Quality(ms: client.quality)
        if NSApp.isActive { clipboard.poll() }
        guard settings.showStats || logStats else { return }
        let s = client.takeStats()
        var text = Self.statsText(s)
        let a = player.buffer.stats
        if player.buffer.idleMs < 2000 {
            text += String(format: "\naudio buffer %.0f ms (target %.0f)  underruns %d", a.depth * 1000, a.target * 1000, a.underruns)
        }
        if settings.showStats { content.stats.text = text }
        if logStats && ticks % 20 == 0, client.proxy != nil {
            Tailnet.shared.path(to: address.host) { p in
                FileHandle.standardError.write(Data("tailnet path: \(p ?? "unknown")\n".utf8))
            }
        }
        if logStats && ticks % 4 == 0 {
            FileHandle.standardError.write(Data((text.replacingOccurrences(of: "\n", with: " | ") + "\n").utf8))
        }
    }

    private static func statsText(_ s: Client.Stats) -> String {
        func f(_ v: Double?, _ spec: String) -> String { v.map { String(format: spec, $0) } ?? "–" }
        var lines: [String] = []
        if let st = s.stream { lines.append("\(st.width)×\(st.height)  \(st.encoder)  \(Int(s.fps.rounded())) fps") }
        lines.append(String(format: "video %.2f Mbps", s.mbps) + (s.host.map { String(format: "  target %.1f Mbps", $0.targetKbps / 1000) } ?? ""))
        lines.append("rtt \(f(s.rtt, "%.1f")) ms  capture→display \(f(s.latency, "%.1f")) ms")
        lines.append(String(format: "decode %.2f ms", s.decodeMs) + (s.hardwareDecoder ? " (hardware)" : "")
                     + (s.host.map { String(format: "  host %.1f+%.1f ms", $0.captureMs, $0.encodeMs) } ?? ""))
        return lines.joined(separator: "\n")
    }

    private func updateTap() {
        let want = !ended && settings.captureSystemKeys && keyboard.captureAll && isConnected && window.isKeyWindow
        if want { keyboard.startTap() } else { keyboard.stopTap() }
    }

    // MARK: - toolbar

    private func toolbarAction(_ item: ToolbarView.Item, _ button: NSButton) {
        switch item {
        case .fullScreen:
            window.toggleFullScreen(nil)
        case .display:
            client.send(Msg.modes)
            model.windowPixels = video.pixelSize
            togglePanel(item, button, DisplayPanel(model: model, settings: settings))
        case .keys:
            model.accessibilityTrusted = KeyboardCapture.accessibilityTrusted
            togglePanel(item, button, KeysPanel(model: model, settings: settings))
        case .clipboard:
            model.localClip = clipboard.local ?? ""
            togglePanel(item, button, ClipboardPanel(model: model))
        case .upload:
            sendFiles(nil)
        case .sound:
            settings.sound.toggle()
        case .stats:
            settings.showStats.toggle()
        case .disconnect:
            end()
        }
    }

    private func togglePanel<V: View>(_ item: ToolbarView.Item, _ button: NSButton, _ view: V) {
        if let p = popover {
            let same = content.toolbar.openPanel == item
            popover = nil
            content.toolbar.openPanel = nil
            p.close()
            if same { return }
        }
        let p = NSPopover()
        p.behavior = .transient
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentViewController = NSHostingController(rootView: view)
        p.delegate = self
        popover = p
        content.toolbar.openPanel = item
        p.show(relativeTo: button.bounds, of: button, preferredEdge: button.isFlipped ? .maxY : .minY)
    }

    private func type(_ text: String) {
        // The host types at most 4096 characters per message.
        var chunk = String.UnicodeScalarView()
        var n = 0                                        // UnicodeScalarView.count is O(n)
        for u in text.unicodeScalars {
            chunk.append(u)
            n += 1
            if n >= Msg.maxTypedText {
                client.send(Msg.txt(String(chunk)))
                chunk = String.UnicodeScalarView()
                n = 0
            }
        }
        if !chunk.isEmpty { client.send(Msg.txt(String(chunk))) }
    }

    private func send(files urls: [URL]) {
        guard isConnected, !urls.isEmpty else { return }
        client.upload(urls)
    }

    private func uploadEvent(_ u: Client.Upload) {
        let toasts = content.toasts
        switch u {
        case .progress(let name, let fraction):
            let text = "Sending \(name)… \(Int(fraction * 100))%"
            if let t = uploadToasts[name] { toasts.update(t, text: text) } else { uploadToasts[name] = toasts.show(text, ttl: nil) }
        case .done(let name, let path):
            if let t = uploadToasts.removeValue(forKey: name) { toasts.remove(t) }
            toasts.show("Saved to " + path.replacingOccurrences(of: #"^/home/[^/]+"#, with: "~", options: .regularExpression))
        case .failed(let name, let reason):
            if let t = uploadToasts.removeValue(forKey: name) { toasts.remove(t) }
            toasts.show("Couldn’t send \(name): \(reason)", error: true, ttl: 6)
        }
    }

    // MARK: - menu actions (the viewer window's delegate is in the responder chain)

    @objc func disconnect(_ sender: Any?) { end() }
    @objc func setFitScale(_ sender: Any?) { settings.scale = .fit }
    @objc func setActualScale(_ sender: Any?) { settings.scale = .actual }
    @objc func toggleStats(_ sender: Any?) { settings.showStats.toggle() }
    @objc func toggleSound(_ sender: Any?) { settings.sound.toggle() }
    @objc func toggleSystemShortcuts(_ sender: Any?) { settings.captureSystemKeys.toggle() }
    @objc func chooseQuality(_ sender: NSMenuItem) { settings.quality = sender.tag }
    @objc func chooseFrameRate(_ sender: NSMenuItem) { settings.fps = sender.tag }
    @objc func chooseCommandKey(_ sender: NSMenuItem) { settings.command = sender.tag == 0 ? .ctrl : .super }

    @objc func toggleKeyboardCapture(_ sender: Any?) {
        releaseInput()
        keyboard.captureAll.toggle()
        updateTap()
        content.toasts.show(keyboard.captureAll ? "Keyboard captured: every key goes to the remote computer."
                                                : "Keyboard released: ⌘ shortcuts work on this Mac. ⌃⌥⌘⎋ captures it again.")
    }

    @objc func sendKeyCombo(_ sender: NSMenuItem) {
        if let codes = sender.representedObject as? [String] { keyboard.combo(codes) }
    }

    @objc func chooseResolution(_ sender: NSMenuItem) {
        model.setResolution(sender.representedObject as? DisplayMode)
    }

    @objc func sendClipboardToRemote(_ sender: Any?) {
        guard let s = clipboard.local, !s.isEmpty else { return }
        model.setRemoteClipboard(s)
    }

    @objc func typeClipboard(_ sender: Any?) {
        if let s = clipboard.local, !s.isEmpty { type(s) }
    }

    @objc func copyRemoteClipboard(_ sender: Any?) {
        guard !clipboard.remote.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(clipboard.remote, forType: .string)
        clipboard.poll()                                 // our own write: don't send it back
        content.toasts.show("Copied")
    }

    @objc func sendFiles(_ sender: Any?) {
        guard isConnected, window.attachedSheet == nil else { return }
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.prompt = "Send"
        p.message = "The files are saved in Downloads/Darpan on the remote computer."
        p.beginSheetModal(for: window) { [weak self] r in
            if r == .OK { self?.send(files: p.urls) }
        }
    }

    /// Resolution submenu: filled when opened, from the latest `modes`.
    func fillResolutionMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        model.windowPixels = video.pixelSize
        client.send(Msg.modes)
        let rows = model.resolutionRows
        if rows.isEmpty {
            menu.addItem(withTitle: "Not available", action: nil, keyEquivalent: "")
            return
        }
        for r in rows {
            let item = NSMenuItem(title: r.detail.isEmpty ? r.title : "\(r.title) (\(r.detail))",
                                  action: #selector(chooseResolution(_:)), keyEquivalent: "")
            item.representedObject = r.mode
            item.state = r.current ? .on : .off
            menu.addItem(item)
        }
    }
}

extension Session: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let live = isConnected
        switch item.action {
        case #selector(setFitScale(_:)): item.state = settings.scale == .fit ? .on : .off
        case #selector(setActualScale(_:)): item.state = settings.scale == .actual ? .on : .off
        case #selector(toggleStats(_:)): item.state = settings.showStats ? .on : .off
        case #selector(toggleSound(_:)): item.state = settings.sound ? .on : .off
        case #selector(chooseQuality(_:)): item.state = settings.quality == item.tag ? .on : .off
        case #selector(chooseFrameRate(_:)): item.state = settings.fps == item.tag ? .on : .off
        case #selector(chooseCommandKey(_:)): item.state = (item.tag == 0) == (settings.command == .ctrl) ? .on : .off
        case #selector(toggleSystemShortcuts(_:)): item.state = settings.captureSystemKeys ? .on : .off
        case #selector(toggleKeyboardCapture(_:)):
            item.title = keyboard.captureAll ? "Release Keyboard" : "Capture Keyboard"
        case #selector(sendKeyCombo(_:)), #selector(chooseResolution(_:)), #selector(typeClipboard(_:)),
             #selector(sendClipboardToRemote(_:)), #selector(sendFiles(_:)):
            return live
        case #selector(copyRemoteClipboard(_:)): return !clipboard.remote.isEmpty
        default: break
        }
        return true
    }
}

extension Session: ClientDelegate {
    func clientStateChanged(_ c: Client) {
        switch c.state {
        case .idle:
            finish(nil)
        case .connecting:
            break
        case .connected:
            if wasConnected {
                // Back after an outage: keys pressed meanwhile never reached this new host session.
                _ = keyboard.reset()
                _ = video.releaseButtons()
            }
            content.overlay.hide()
            if !wasConnected {
                wasConnected = true
                // Remember unticked: forget a sign-in saved earlier, even if it was just used.
                if remember == false { Keychain.delete(address.origin) }
                showWindow()
                owner?.sessionDidConnect(self)
            }
            updateTicker()
            updateTap()
        case .reconnecting(let restarting):
            guard wasConnected else { return }
            _ = keyboard.reset()                         // that host session is gone, and with it what it held
            _ = video.releaseButtons()
            content.overlay.show(restarting ? "Remote computer restarting…" : "Reconnecting…")
            updateTicker()
            updateTap()
        case .failed(let f):
            finish(f)
        }
    }

    func client(_ c: Client, received e: Client.Event) {
        switch e {
        case .welcome(let w):
            window.title = w.hostName ?? address.shortName
            if !wasConnected { sizeWindow(for: w.screen) }
        case .stream(let s):
            video.streamSize = CGSize(width: s.width, height: s.height)
        case .screen:
            break                                         // a new stream follows
        case .cursor(let cur):
            video.setCursor(cur)
        case .clipboard(let text, let initial):
            clipboard.received(text, initial: initial)
            model.remoteClip = text
        case .modes(let m):
            model.modes = m
        case .notice(let text, let error):
            content.toasts.show(text, error: error, ttl: error ? 8 : 3.5)
        case .upload(let u):
            uploadEvent(u)
        case .authenticated(let key):
            if remember == true { Keychain.save(key, for: address.origin) } else if remember == false { Keychain.delete(address.origin) }
        case .forgetKey:
            Keychain.delete(address.origin)
        }
    }
}

extension Session: VideoViewDelegate {
    func send(_ message: String?) { client.send(message) }
    func videoView(_ view: VideoView, rawKey event: NSEvent) { keyboard.keyDown(event) }
    func videoView(_ view: VideoView, typed text: String) { type(text) }
    func videoView(_ view: VideoView, dropped files: [URL]) { send(files: files) }
    func videoViewPointerDown(_ view: VideoView) { popover?.close() }
    var canAcceptFiles: Bool { isConnected }

    func videoViewMarkedTextChanged(_ view: VideoView) {
        content.composition.text = view.markedText
        content.composition.isHidden = view.markedText.isEmpty
        content.needsLayout = true
    }
}

extension Session: NSWindowDelegate {
    func windowDidChangeOcclusionState(_ n: Notification) {
        let visible = window.occlusionState.contains(.visible)
        client.setVideoActive(visible)                   // hidden → `stop`: the host encoder idles
        if !visible { releaseInput() }
        updateTicker()
    }

    func windowDidBecomeKey(_ n: Notification) {
        if window.firstResponder !== video { window.makeFirstResponder(video) }
        updateTap()
    }

    func windowDidResignKey(_ n: Notification) {
        releaseInput()
        updateTap()
    }

    func windowWillClose(_ n: Notification) {
        guard !ended else { return }
        releaseInput()
        client.disconnect()
        finish(nil, closeWindow: false)
    }

    func windowDidEnterFullScreen(_ n: Notification) { content.toolbar.isFullScreen = true }
    func windowDidExitFullScreen(_ n: Notification) { content.toolbar.isFullScreen = false }
}

extension Session: NSPopoverDelegate {
    func popoverDidClose(_ n: Notification) {
        guard let p = n.object as? NSPopover, p === popover else { return }
        popover = nil
        content.toolbar.openPanel = nil
        window.makeFirstResponder(video)
    }
}
