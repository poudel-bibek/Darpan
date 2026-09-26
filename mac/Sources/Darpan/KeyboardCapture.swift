import AppKit
import Carbon.HIToolbox
import DarpanCore

/// Keys → remote computer.
///
/// While the viewer is the key window every key goes to the remote (⌘Q, ⌘W, ⌘H… included),
/// taken from a local event monitor before menus see it. Only the reserved shortcuts stay on
/// the Mac: ⌃⌥⌘D disconnect, ⌃⌥⌘F full screen, ⌃⌥⌘⎋ release/capture the keyboard.
/// With the keyboard released, menu shortcuts work locally and other keys still go through.
///
/// Optionally (setting + Accessibility permission) an event tap also takes the shortcuts macOS
/// handles itself — ⌘Tab, ⌘Space, Mission Control — but only while the viewer is key.
final class KeyboardCapture {
    let translator = KeyboardTranslator()
    /// Every key goes to the remote (⌃⌥⌘⎋ toggles).
    var captureAll = true
    /// ⌘V or ⌃V is about to go out: bring the remote clipboard up to date first. False: it
    /// couldn't be (too large), so the paste isn't sent; the remote would paste something stale.
    var beforePaste: (() -> Bool)?
    var send: ((String) -> Void)?

    private weak var video: VideoView?
    private var monitor: Any?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var inputMethodActive = false
    private var sourceObserver: NSObjectProtocol?

    init(video: VideoView) {
        self.video = video
        video.keyHandler = { [weak self] e in if !Self.isReserved(e) { self?.handle(e) } }
        refreshInputSource()
        sourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil,
            queue: .main) { [weak self] _ in self?.refreshInputSource() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            guard let self, self.captureAll, self.isCapturing(e.window), !Self.isReserved(e) else { return e }
            self.handle(e)
            return nil
        }
    }

    func invalidate() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let sourceObserver { DistributedNotificationCenter.default().removeObserver(sourceObserver) }
        sourceObserver = nil
        stopTap()
        video?.keyHandler = nil
    }

    deinit { invalidate() }

    /// The viewer lost the keyboard: forget held keys. True if the host should get `rel`.
    func reset() -> Bool {
        video?.cancelComposition()
        return translator.reset()
    }

    /// Whether the viewer is taking keys right now.
    var isActive: Bool { isCapturing(video?.window) }

    private func isCapturing(_ w: NSWindow?) -> Bool {
        guard let w, let video, w === video.window, w.isKeyWindow, w.firstResponder === video else { return false }
        return true
    }

    // MARK: - events

    func handle(_ e: NSEvent) {
        #if DEBUG
        if Self.logKeys {
            let chars = e.type == .flagsChanged ? "" : (e.characters ?? "").unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            let src = e.cgEvent.map { "pid=\($0.getIntegerValueField(.eventSourceUnixProcessID)) state=\($0.getIntegerValueField(.eventSourceStateID))" } ?? "-"
            FileHandle.standardError.write(Data(String(format: "[keys] %@ code=0x%02X flags=0x%08lX rep=%d chars=%@ %@\n",
                "\(e.type == .keyDown ? "down" : e.type == .keyUp ? "up" : "flags")", e.keyCode, e.modifierFlags.rawValue,
                e.type == .keyDown && e.isARepeat ? 1 : 0, chars, src).utf8))
        }
        #endif
        switch e.type {
        case .keyDown:
            let f = e.modifierFlags
            if let video, !f.contains(.command) && !f.contains(.control) && (inputMethodActive || video.hasMarkedText()) {
                video.interpret(e)
            } else {
                keyDown(e)
            }
        case .keyUp:
            out(translator.keyUp(keyCode: e.keyCode, flags: e.modifierFlags.rawValue))
        case .flagsChanged:
            out(translator.flagsChanged(keyCode: e.keyCode, flags: e.modifierFlags.rawValue))
        default:
            break
        }
    }

    /// A key press that goes out as a key (also the input method's pass-through keys).
    func keyDown(_ e: NSEvent) {
        let f = e.modifierFlags
        // Paste is ⌘V by character: dictation apps post the layout's V key, which isn't key code 9
        // on Dvorak or AZERTY.
        let isV = e.keyCode == KeyCodes.v || e.charactersIgnoringModifiers?.lowercased() == "v"
        if isV && !e.isARepeat && (f.contains(.command) || f.contains(.control)) && !f.contains(.option) {
            if beforePaste?() == false { return }
        }
        out(translator.keyDown(keyCode: e.keyCode, isRepeat: e.isARepeat, flags: f.rawValue))
    }

    func combo(_ codes: [String]) { out(KeyboardTranslator.combo(codes)) }

    private func out(_ events: [KeyEvent]) {
        for k in events { send?(Msg.key(k.code, k.down, cmd: k.cmd)) }
    }

    /// ⌃⌥⌘D, ⌃⌥⌘F, ⌃⌥⌘⎋: handled by the menu even while keys are captured.
    static func isReserved(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown || e.type == .keyUp,
              e.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .option, .control] else {
            return false
        }
        return e.keyCode == KeyCodes.escape || e.keyCode == UInt16(kVK_ANSI_D) || e.keyCode == UInt16(kVK_ANSI_F)
    }

    /// Never taken by the event tap: Force Quit (⌥⌘⎋) and Lock Screen (⌃⌘Q).
    private static func isSystemSafety(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags.intersection([.command, .option, .control, .shift])
        return (f == [.command, .option] && e.keyCode == KeyCodes.escape)
            || (f == [.command, .control] && e.keyCode == UInt16(kVK_ANSI_Q))
    }

    private func refreshInputSource() {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceType) else {
            inputMethodActive = false
            return
        }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
        inputMethodActive = !CFEqual(type, kTISTypeKeyboardLayout)
    }

    // MARK: - system shortcuts (event tap)

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    #if DEBUG
    /// DARPAN_LOG_KEYS=1: every key event on stderr (type, key code, raw flags, characters, source).
    static let logKeys = ProcessInfo.processInfo.environment["DARPAN_LOG_KEYS"] != nil
    #endif

    /// Shows the system prompt that leads to Privacy & Security → Accessibility.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    var tapRunning: Bool { tap != nil }

    /// Installs the tap if allowed; call when the viewer becomes key.
    func startTap() {
        guard tap == nil, Self.accessibilityTrusted else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: tapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tap = port
        tapSource = source
    }

    func stopTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        tapSource = nil
    }

    fileprivate func tapped(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Input methods need AppKit's normal path; so do the reserved shortcuts.
        guard type == .keyDown || type == .keyUp, captureAll, isActive, !inputMethodActive, video?.hasMarkedText() == false,
              let e = NSEvent(cgEvent: event), !Self.isReserved(e), !Self.isSystemSafety(e) else {
            return Unmanaged.passUnretained(event)
        }
        handle(e)
        return nil
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, info in
    guard let info else { return Unmanaged.passUnretained(event) }
    return Unmanaged<KeyboardCapture>.fromOpaque(info).takeUnretainedValue().tapped(type, event)
}

/// Text clipboard ⇄ remote (PROTOCOL.md §6). macOS has no clipboard change notification, so
/// the change count is polled — twice a second, and only while connected and this app is
/// active; on activation it's checked at once. Neither direction echoes.
final class ClipboardSync {
    private let pasteboard = NSPasteboard.general
    private var seen: Int
    private var lastSent: String?
    private var holdUntil = 0.0                     // Clock.nowMs: no automatic sync until then
    private(set) var remote = ""
    private let send: (String) -> Void

    /// Marked by password managers (nspasteboard.org): not sent automatically.
    private static let privateTypes: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"),
    ]

    init(send: @escaping (String) -> Void) {
        self.send = send
        seen = pasteboard.changeCount       // what was copied before connecting stays local until pasted
    }

    /// The Mac's clipboard changed since the last look: send it.
    func poll() {
        // Right after a paste sync, apps that paste for you (dictation, text expanders) put the
        // old clipboard back; sending that at once could overtake the paste on the host.
        guard Clock.nowMs() >= holdUntil else { return }
        let n = pasteboard.changeCount
        guard n != seen else { return }
        seen = n
        guard let types = pasteboard.types, !types.contains(where: Self.privateTypes.contains) else { return }
        offer(pasteboard.string(forType: .string))
    }

    /// Right before ⌘V goes out: make sure the remote pastes what this Mac has.
    /// Returns false if the text was too large to send.
    @discardableResult
    func beforePaste() -> Bool {
        seen = pasteboard.changeCount
        guard let s = pasteboard.string(forType: .string) else { return true }
        guard s.utf8.count <= Msg.maxClipboardBytes else { return false }
        if offer(s) { holdUntil = Clock.nowMs() + 1000 }
        return true
    }

    var local: String? { pasteboard.string(forType: .string) }

    /// Text from the remote. The first one after connecting is only remembered.
    func received(_ text: String, initial: Bool) {
        remote = text
        lastSent = nil                      // the remote has this now; anything else is news again
        guard !initial, text != pasteboard.string(forType: .string) else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        seen = pasteboard.changeCount
    }

    /// Sets the remote clipboard explicitly (clipboard panel).
    func setRemote(_ text: String) {
        lastSent = text
        send(text)
    }

    @discardableResult
    private func offer(_ s: String?) -> Bool {
        guard let s, !s.isEmpty, s != lastSent, s != remote, s.utf8.count <= Msg.maxClipboardBytes else { return false }
        lastSent = s
        send(s)
        return true
    }
}
