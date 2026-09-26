import CoreGraphics
import Foundation
import DarpanCore

func inputTests() {
    section("key map sanity") {
        let valid: Set<String> = {
            var s: Set<String> = ["Escape", "Backquote", "Minus", "Equal", "Backspace", "Tab", "BracketLeft", "BracketRight",
                                  "Backslash", "CapsLock", "Semicolon", "Quote", "Enter", "ShiftLeft", "ShiftRight", "Comma",
                                  "Period", "Slash", "ControlLeft", "ControlRight", "MetaLeft", "MetaRight", "AltLeft",
                                  "AltRight", "Space", "ContextMenu", "IntlBackslash", "IntlRo", "IntlYen", "Insert",
                                  "Delete", "Home", "End", "PageUp", "PageDown", "ArrowUp", "ArrowDown", "ArrowLeft",
                                  "ArrowRight", "PrintScreen", "ScrollLock", "Pause", "NumLock", "NumpadDivide",
                                  "NumpadMultiply", "NumpadSubtract", "NumpadAdd", "NumpadEnter", "NumpadDecimal",
                                  "NumpadEqual", "NumpadComma", "AudioVolumeMute", "AudioVolumeDown", "AudioVolumeUp",
                                  "MediaPlayPause", "MediaStop", "MediaTrackNext", "MediaTrackPrevious", "Lang1", "Lang2",
                                  "KanaMode", "Convert", "NonConvert"]
            for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" { s.insert("Key\(c)") }
            for d in 0...9 { s.insert("Digit\(d)"); s.insert("Numpad\(d)") }
            for f in 1...24 { s.insert("F\(f)") }
            return s
        }()
        eq(keyCodeMap.count, 119, "entries (MAC_PROMPT §4)")
        for (kc, code) in keyCodeMap { check(valid.contains(code), "0x\(String(kc, radix: 16)) → \(code) is a PROTOCOL §10 code") }
        eq(Set(keyCodeMap.values).count, keyCodeMap.count, "no two key codes share a code")
        for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" { check(keyCodeMap.values.contains("Key\(c)"), "Key\(c) present") }
        for d in 0...9 { check(keyCodeMap.values.contains("Digit\(d)"), "Digit\(d) present") }
        for f in 1...20 { check(keyCodeMap.values.contains("F\(f)"), "F\(f) present") }
        eq(keyCodeMap[0x00], "KeyA", "0x00")
        eq(keyCodeMap[0x24], "Enter", "0x24")
        eq(keyCodeMap[0x33], "Backspace", "0x33")
        eq(keyCodeMap[0x75], "Delete", "0x75 forward delete")
        eq(keyCodeMap[0x7E], "ArrowUp", "0x7E")
        eq(keyCodeMap[0x3F], nil, "Fn is not sent")
    }

    section("keyboard translation") {
        let F = ModifierBits.self
        let cmdL = F.command | F.leftCommand, ctrlL = F.control | F.leftControl
        let kb = KeyboardTranslator()
        // ⌘C with ⌘ → Ctrl
        eq(kb.flagsChanged(keyCode: 0x37, flags: cmdL), [KeyEvent("ControlLeft", true)], "⌘ down → ControlLeft")
        eq(kb.keyDown(keyCode: 0x08, isRepeat: false, flags: cmdL), [KeyEvent("KeyC", true), KeyEvent("KeyC", false)],
           "C pressed while ⌘ held → down+up at once")
        eq(kb.keyUp(keyCode: 0x08, flags: cmdL), [], "its key-up adds nothing")
        eq(kb.keyDown(keyCode: 0x7B, isRepeat: true, flags: cmdL), [KeyEvent("ArrowLeft", true), KeyEvent("ArrowLeft", false)],
           "auto-repeat under ⌘ → one pair per repeat")
        eq(kb.flagsChanged(keyCode: 0x37, flags: 0), [KeyEvent("ControlLeft", false)], "⌘ up")
        check(kb.isIdle, "idle after ⌘C")

        // ⌃ and ⌘ both map to ControlLeft: one down, one up, released when both are up.
        eq(kb.flagsChanged(keyCode: 0x3B, flags: ctrlL), [KeyEvent("ControlLeft", true)], "⌃ down")
        eq(kb.flagsChanged(keyCode: 0x37, flags: ctrlL | cmdL), [], "⌘ down while ⌃ held: nothing new")
        eq(kb.flagsChanged(keyCode: 0x3B, flags: cmdL), [], "⌃ up while ⌘ held: still held")
        eq(kb.flagsChanged(keyCode: 0x37, flags: 0), [KeyEvent("ControlLeft", false)], "both up → released")

        // Right-hand modifiers by device bit; missing device bits fall back to the key that changed.
        eq(kb.flagsChanged(keyCode: 0x3C, flags: F.shift | F.rightShift), [KeyEvent("ShiftRight", true)], "right shift")
        eq(kb.flagsChanged(keyCode: 0x3C, flags: 0), [KeyEvent("ShiftRight", false)], "right shift up")
        eq(kb.flagsChanged(keyCode: 0x3D, flags: F.option), [KeyEvent("AltRight", true)], "no device bits: right option by key code")
        eq(kb.flagsChanged(keyCode: 0x3D, flags: 0), [KeyEvent("AltRight", false)], "released")
        eq(kb.keyDown(keyCode: 0x00, isRepeat: false, flags: F.shift),
           [KeyEvent("ShiftLeft", true), KeyEvent("KeyA", true)], "shift seen only in a key event's flags is synced first")
        eq(kb.keyUp(keyCode: 0x00, flags: 0), [KeyEvent("KeyA", false), KeyEvent("ShiftLeft", false)], "and released after")

        // Auto-repeat → extra downs; a second press without a release → down again.
        eq(kb.keyDown(keyCode: 0x02, isRepeat: false, flags: 0), [KeyEvent("KeyD", true)], "D")
        eq(kb.keyDown(keyCode: 0x02, isRepeat: true, flags: 0), [KeyEvent("KeyD", true)], "repeat")
        eq(kb.keyDown(keyCode: 0x02, isRepeat: false, flags: 0), [KeyEvent("KeyD", true)], "missed release")
        eq(kb.keyUp(keyCode: 0x02, flags: 0), [KeyEvent("KeyD", false)], "one up")
        eq(kb.keyUp(keyCode: 0x02, flags: 0), [], "unknown up ignored")

        // CapsLock: a pair per state change.
        eq(kb.flagsChanged(keyCode: 0x39, flags: F.capsLock), [KeyEvent("CapsLock", true), KeyEvent("CapsLock", false)], "caps on")
        eq(kb.flagsChanged(keyCode: 0x39, flags: 0), [KeyEvent("CapsLock", true), KeyEvent("CapsLock", false)], "caps off")
        eq(kb.flagsChanged(keyCode: 0x39, flags: 0), [], "no change, no pair")

        // A key pressed before ⌘ keeps repeating as a held key, and is released when ⌘ goes up
        // (its key-up may never arrive).
        _ = kb.keyDown(keyCode: 0x01, isRepeat: false, flags: 0)
        eq(kb.flagsChanged(keyCode: 0x37, flags: cmdL), [KeyEvent("ControlLeft", true)], "⌘ down while S held")
        eq(kb.keyDown(keyCode: 0x01, isRepeat: true, flags: cmdL), [KeyEvent("KeyS", true)], "S repeats as held")
        eq(kb.flagsChanged(keyCode: 0x37, flags: 0), [KeyEvent("ControlLeft", false), KeyEvent("KeyS", false)], "⌘ up releases S")
        eq(kb.keyUp(keyCode: 0x01, flags: 0), [], "late S up ignored")

        // ⌘ → Super; the code used at press time is used for the release.
        kb.command = .super
        eq(kb.flagsChanged(keyCode: 0x36, flags: F.command | F.rightCommand), [KeyEvent("MetaRight", true)], "⌘ → Super")
        kb.command = .ctrl
        eq(kb.flagsChanged(keyCode: 0x36, flags: 0), [KeyEvent("MetaRight", false)], "released as MetaRight")

        _ = kb.keyDown(keyCode: 0x0C, isRepeat: false, flags: 0)
        check(kb.reset(), "reset reports held keys")
        check(kb.isIdle && !kb.reset(), "idle after reset")
        eq(kb.keyDown(keyCode: 0x3F, isRepeat: false, flags: 0), [], "Fn ignored")
        eq(KeyboardTranslator.combo(["ControlLeft", "AltLeft", "KeyT"]).map(\.description),
           ["ControlLeft↓", "AltLeft↓", "KeyT↓", "KeyT↑", "AltLeft↑", "ControlLeft↑"], "combo order")
    }

    section("wheel sign and units") {
        var w = WheelAccumulator()
        // Trackpad: fingers move up → content moves up → scrollingDeltaY < 0 → scroll down → dy > 0.
        let t = w.add(deltaX: 0, deltaY: -10, precise: true)
        eq(t?.dy, 24, "trackpad 10 px down-scroll → +24")
        eq(t?.dx, 0, "no horizontal")
        // Mouse wheel one notch towards the user (content down) → deltaY = +1 → scroll up.
        eq(w.add(deltaX: 0, deltaY: 1, precise: false)?.dy, -120, "wheel notch up → −120")
        eq(w.add(deltaX: -1, deltaY: 0, precise: false)?.dx, 120, "wheel right → +120")
        // Fractions carry over.
        w.reset()
        check(w.add(deltaX: 0, deltaY: -0.3, precise: true) == nil, "0.72 units → nothing yet")
        eq(w.add(deltaX: 0, deltaY: -0.3, precise: true)?.dy, 1, "1.44 → 1 sent, 0.44 kept")
        eq(w.add(deltaX: 0, deltaY: -0.25, precise: true)?.dy, 1, "0.44 + 0.6 = 1.04 → 1")
        var inv = WheelAccumulator(speed: 2, invert: true)
        eq(inv.add(deltaX: 0, deltaY: -10, precise: true)?.dy, -48, "speed ×2, reversed")
        eq(protocolButton(0), 0, "left")
        eq(protocolButton(1), 2, "right")
        eq(protocolButton(2), 1, "middle")
        eq(protocolButton(3), 3, "back")
        eq(protocolButton(4), 4, "forward")
        eq(protocolButton(5), nil, "others ignored")
    }

    section("pointer geometry") {
        // 2560×1440 stream in a 1000×700 pt view on a Retina display: letterboxed top/bottom.
        let r = VideoGeometry.videoRect(mode: .fit, stream: CGSize(width: 2560, height: 1440),
                                        bounds: CGSize(width: 1000, height: 700), backingScale: 2, pointer: nil)
        eq(r.width, 1000, "fit width")
        eq(r.height, 562.5, "fit height (device-pixel aligned)")
        eq(r.minY, 69, "centred vertically")
        let p = VideoGeometry.streamPoint(CGPoint(x: 500, y: 69 + 281.25), videoRect: r, streamWidth: 2560, streamHeight: 1440)
        eq(p.x, 1280, "centre x")
        eq(p.y, 720, "centre y")
        let tl = VideoGeometry.streamPoint(CGPoint(x: -5, y: 10), videoRect: r, streamWidth: 2560, streamHeight: 1440)
        eq(tl.x, 0, "clamped left")
        eq(tl.y, 0, "clamped top (letterbox)")
        let br = VideoGeometry.streamPoint(CGPoint(x: 1000, y: 700), videoRect: r, streamWidth: 2560, streamHeight: 1440)
        eq(br.x, 2559, "clamped right")
        eq(br.y, 1439, "clamped bottom")

        // Actual pixels: 2560×1440 at 2× = 1280×720 pt in a 1000×800 view: pans horizontally, centred vertically.
        let bounds = CGSize(width: 1000, height: 800)
        for x in [0.0, 250, 500, 999] {
            let a = VideoGeometry.videoRect(mode: .actual, stream: CGSize(width: 2560, height: 1440), bounds: bounds,
                                            backingScale: 2, pointer: CGPoint(x: x, y: 400))
            eq(a.width, 1280, "actual width")
            eq(a.minY, 40, "centred vertically")
            let q = VideoGeometry.streamPoint(CGPoint(x: x, y: 400), videoRect: a, streamWidth: 2560, streamHeight: 1440)
            check(abs(q.x - Int(x * 2.56)) <= 1, "panned mapping at x=\(x): \(q.x)")
        }
        let modes = [DisplayMode(3840, 2160), DisplayMode(2560, 1440), DisplayMode(1920, 1200), DisplayMode(1920, 1080), DisplayMode(1280, 720)]
        eq(DisplayMode.bestFor(window: CGSize(width: 1920, height: 1200), among: modes), DisplayMode(1920, 1200), "16:10 window → 16:10")
        eq(DisplayMode.bestFor(window: CGSize(width: 2560, height: 1600), among: modes), DisplayMode(2560, 1440), "area outweighs a small aspect difference")
        eq(DisplayMode.bestFor(window: CGSize(width: 2000, height: 1125), among: modes), DisplayMode(1920, 1080), "16:9 window")
        eq(DisplayMode.bestFor(window: CGSize(width: 100, height: 100), among: modes), nil, "nothing fits")
    }
}
