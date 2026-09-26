#if DEBUG
import AppKit
import DarpanCore
import ImageIO
import VideoToolbox

/// Test hooks, debug builds only (release builds don't contain them). With
/// DARPAN_DEBUG_CMDS=<file> the app follows commands appended to that file: synthetic input
/// through the normal event path, window actions, and snapshots (the last decoded frame
/// composited with the overlays). Driving the app from outside would need Accessibility and
/// Screen Recording permissions; this doesn't.
enum DebugHooks {
    static let enabled = ProcessInfo.processInfo.environment["DARPAN_DEBUG_CMDS"] != nil
    private static var handle: FileHandle?
    private static var buffer = ""
    private static var timer: Timer?
    private static weak var app: AppDelegate?

    static func install(_ app: AppDelegate) {
        guard let path = ProcessInfo.processInfo.environment["DARPAN_DEBUG_CMDS"] else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forReadingAtPath: path)
        self.app = app
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in poll() }
        say("reading commands from \(path)")
    }

    static func say(_ s: String) {
        FileHandle.standardError.write(Data((String(format: "[debug %.3f] ", Clock.nowMs() / 1000) + s + "\n").utf8))
    }

    private static func poll() {
        guard let d = handle?.readDataToEndOfFile(), !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
        buffer += s
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl]).trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(...nl)
            if !line.isEmpty { run(line) }
        }
    }

    private static func run(_ line: String) {
        let a = line.split(separator: " ").map(String.init)
        let rest = a.count > 1 ? String(line.dropFirst(a[0].count + 1)) : ""
        let s = app?.debugSession
        let w = s?.window
        func num(_ i: Int) -> Double { a.count > i ? Double(a[i]) ?? 0 : 0 }
        switch a[0] {
        case "geom":
            say(geometry(s))
        case "snap":
            snapshot(s, to: a.count > 1 ? a[1] : "/tmp/darpan-snap.png")
        case "connect":                                   // connect <address> <password|->
            guard let m = app?.debugConnectModel, a.count > 2 else { return }
            m.address = a[1]
            m.password = a[2] == "-" ? "" : a[2]
            m.connect(remember: a.count > 3 && a[3] == "remember")
        case "state":
            let m = app?.debugConnectModel
            say("connect: \"\(m?.message ?? "")\" connecting=\(m?.connecting ?? false) countdown=\(m?.countdown ?? 0) "
                + "session=\(s.map { "\($0.client.state)" } ?? "none") tailnet=\(Tailnet.shared.phase)")
        case "key":                                       // key <keyCode> <mods|none> [down|up|tap] [repeat]
            guard let w, a.count > 1, let code = UInt16(a[1]) else { return }
            let f = flags(a.count > 2 ? a[2] : "none")
            let phase = a.count > 3 ? a[3] : "tap"
            let rep = a.count > 4 && a[4] == "repeat"
            if phase != "up" { post(key(.keyDown, code, f, rep, w)) }
            if phase != "down" { post(key(.keyUp, code, f, false, w)) }
        case "flags":                                     // flags <keyCode> <mods|none>
            guard let w, a.count > 2, let code = UInt16(a[1]) else { return }
            post(key(.flagsChanged, code, flags(a[2]), false, w))
        case "move":                                      // move <x> <y> (view points, top-left)
            guard let s, let e = mouse(.mouseMoved, CGPoint(x: num(1), y: num(2)), s) else { return }
            s.debugContent.video.mouseMoved(with: e)
        case "click":                                     // click <x> <y> [left|right]
            guard let s else { return }
            let right = a.count > 3 && a[3] == "right"
            let p = CGPoint(x: num(1), y: num(2))
            post(mouse(right ? .rightMouseDown : .leftMouseDown, p, s))
            post(mouse(right ? .rightMouseUp : .leftMouseUp, p, s))
        case "scroll":                                    // scroll <dy> [dx] [lines]
            guard let s, let cg = CGEvent(scrollWheelEvent2Source: nil, units: a.contains("lines") ? .line : .pixel,
                                          wheelCount: 2, wheel1: Int32(num(1)), wheel2: Int32(num(2)), wheel3: 0),
                  let e = NSEvent(cgEvent: cg) else { return }
            s.debugContent.video.scrollWheel(with: e)
        case "type":                                      // text from an input method / dictation
            s?.debugContent.video.insertText(rest, replacementRange: NSRange(location: NSNotFound, length: 0))
        case "compose":                                   // marked text, then `type` commits it
            s?.debugContent.video.setMarkedText(rest, selectedRange: NSRange(location: rest.utf16.count, length: 0),
                                                replacementRange: NSRange(location: NSNotFound, length: 0))
        case "toolbar":                                   // toolbar <item>
            let items: [String: ToolbarView.Item] = ["fullscreen": .fullScreen, "display": .display, "keys": .keys,
                                                      "upload": .upload, "stats": .stats,
                                                      "disconnect": .disconnect]
            if let item = items[a.count > 1 ? a[1] : ""] { s?.debugToolbar(item) } else { s?.debugContent.toolbar.expand() }
        case "menu":                                      // menu <exact item title>
            if let item = find(rest, in: NSApp.mainMenu), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            } else {
                say("no menu item \"\(rest)\"")
            }
        case "scale": Settings.shared.scale = a.count > 1 && a[1] == "actual" ? .actual : .fit
        case "stats": Settings.shared.showStats = a.count > 1 && a[1] == "on"
        case "fps": Settings.shared.fps = Int(num(1))
        case "quality": Settings.shared.quality = Int(num(1))
        case "command": Settings.shared.command = a.count > 1 && a[1] == "super" ? .super : .ctrl
        case "res":
            s?.debugModel.setResolution(a.count > 2 ? DisplayMode(Int(num(1)), Int(num(2))) : nil)
        case "size": w?.setContentSize(NSSize(width: num(1), height: num(2)))
        case "fullscreen": w?.toggleFullScreen(nil)
        case "mini": w?.miniaturize(nil)
        case "demini": w?.deminiaturize(nil)
        case "hide": NSApp.hide(nil)
        case "unhide":
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
        case "pb":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rest, forType: .string)
        case "pbget": say("pasteboard: \(NSPasteboard.general.string(forType: .string)?.debugDescription ?? "nil")")
        case "upload": s?.client.upload(a.dropFirst().map { URL(fileURLWithPath: $0) })
        case "drophl": s?.debugContent.drop.isHidden = !(a.count > 1 && a[1] == "on")   // drop highlight on/off
        case "toast": s?.debugContent.toasts.show(rest, ttl: 20)
        case "close": w?.performClose(nil)
        case "quit": NSApp.terminate(nil)
        default: say("unknown command: \(line)")
        }
    }

    private static func post(_ e: NSEvent?) {
        if let e { NSApp.postEvent(e, atStart: false) }
    }

    /// "cmd,shift" → flags with left-side device bits, like a real keyboard.
    private static func flags(_ spec: String) -> NSEvent.ModifierFlags {
        var raw: UInt = 0
        for p in spec.split(separator: ",") {
            switch p {
            case "cmd": raw |= ModifierBits.command | ModifierBits.leftCommand
            case "rcmd": raw |= ModifierBits.command | ModifierBits.rightCommand
            case "shift": raw |= ModifierBits.shift | ModifierBits.leftShift
            case "ctrl": raw |= ModifierBits.control | ModifierBits.leftControl
            case "opt": raw |= ModifierBits.option | ModifierBits.leftOption
            case "caps": raw |= ModifierBits.capsLock
            case "cmdsynth": raw |= ModifierBits.command            // ⌘ bit only, as dictation apps post it
            default: break
            }
        }
        return NSEvent.ModifierFlags(rawValue: raw)
    }

    private static func key(_ type: NSEvent.EventType, _ code: UInt16, _ f: NSEvent.ModifierFlags, _ rep: Bool,
                            _ w: NSWindow) -> NSEvent? {
        let table: [UInt16: String] = [0: "a", 1: "s", 2: "d", 3: "f", 8: "c", 9: "v", 12: "q", 13: "w", 0x35: "\u{1b}", 0x24: "\r"]
        let chars = type == .flagsChanged ? "" : table[code] ?? "x"
        return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: f, timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: w.windowNumber, context: nil, characters: chars,
                                charactersIgnoringModifiers: chars, isARepeat: rep, keyCode: code)
    }

    private static func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ s: Session) -> NSEvent? {
        let v = s.debugContent.video
        return NSEvent.mouseEvent(with: type, location: v.convert(p, to: nil), modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: s.window.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    private static func find(_ title: String, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.title == title { return item }
            if let sub = item.submenu {
                sub.update()
                if let hit = find(title, in: sub) { return hit }
            }
        }
        return nil
    }

    private static func geometry(_ s: Session?) -> String {
        guard let s else { return "no session" }
        let w = s.window, c = s.debugContent, v = c.video
        return "window \(w.frame) content \(c.bounds.size) scale \(w.backingScaleFactor) stream \(v.streamSize) "
            + "video \(v.videoRect) toolbar \(c.toolbar.frame) expanded=\(c.toolbar.expanded) key=\(w.isKeyWindow) "
            + "visible=\(w.occlusionState.contains(.visible)) fullscreen=\(w.styleMask.contains(.fullScreen)) "
            + "responder=\(w.firstResponder.map { "\(type(of: $0))" } ?? "nil") state=\(s.client.state)"
    }

    /// The last decoded frame drawn into the video rectangle, with the overlays rendered on top.
    private static func snapshot(_ s: Session?, to path: String) {
        guard let s else { return say("no session") }
        let root = s.debugContent
        let scale = s.window.backingScaleFactor
        let W = root.bounds.width, H = root.bounds.height
        guard let ctx = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let v = root.video
        if let frame = v.debugLastFrame {
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(frame, options: nil, imageOut: &image)
            if let image {
                let r = v.videoRect
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height))
            }
        }
        for sub in root.subviews where sub !== v && !sub.isHidden {
            guard let layer = sub.layer else { continue }
            ctx.saveGState()
            ctx.translateBy(x: sub.frame.minX, y: H - sub.frame.maxY)
            layer.render(in: ctx)
            ctx.restoreGState()
        }
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        say("snapshot \(path): " + geometry(s))
    }
}
#endif
