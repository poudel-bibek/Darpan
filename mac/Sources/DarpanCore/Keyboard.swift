import Foundation

/// What ⌘ Command sends to the Linux host (PROTOCOL.md §5, "Mac guidance").
public enum CommandKey: String, CaseIterable {
    case ctrl
    case `super`
}

/// One `key` message.
public struct KeyEvent: Equatable, CustomStringConvertible {
    public let code: String
    public let down: Bool
    public init(_ code: String, _ down: Bool) { self.code = code; self.down = down }
    public var description: String { code + (down ? "↓" : "↑") }
}

/// NSEvent.modifierFlags bits (device-independent ones from NSEvent, device-dependent ones
/// from IOKit's NX_DEVICE*KEYMASK, which tell left and right apart).
public enum ModifierBits {
    public static let capsLock: UInt = 1 << 16
    public static let shift: UInt = 1 << 17
    public static let control: UInt = 1 << 18
    public static let option: UInt = 1 << 19
    public static let command: UInt = 1 << 20

    public static let leftControl: UInt = 0x0000_0001
    public static let leftShift: UInt = 0x0000_0002
    public static let rightShift: UInt = 0x0000_0004
    public static let leftCommand: UInt = 0x0000_0008
    public static let rightCommand: UInt = 0x0000_0010
    public static let leftOption: UInt = 0x0000_0020
    public static let rightOption: UInt = 0x0000_0040
    public static let rightControl: UInt = 0x0000_2000
}

public enum KeyCodes {
    public static let capsLock: UInt16 = 0x39
    public static let function: UInt16 = 0x3F
    public static let escape: UInt16 = 0x35
    public static let v: UInt16 = 0x09
    public static let modifiers: Set<UInt16> = [0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F]
}

/// Turns macOS key events into `key` messages.
///
/// * Keys are physical positions (`NSEvent.keyCode` → W3C `code`, table in KeyCodeMap.swift).
/// * Modifier state is taken from the event's flags on every event and diffed against what the
///   host was told, so a missed `flagsChanged` can never leave a modifier stuck. Left and right
///   come from the device-dependent bits.
/// * ⌘ → ControlLeft/Right (default) or MetaLeft/Right. Remote codes are reference counted:
///   with ⌘ → Ctrl, holding ⌃ and ⌘ together only releases ControlLeft once both are up.
/// * CapsLock is a toggle on macOS: every state change becomes a down+up pair.
/// * An OS auto-repeat `keyDown` is sent as another `d:true` (the host turns it into up+down).
/// * A key pressed while ⌘ is held is sent as an immediate down+up pair (PROTOCOL.md §5): AppKit
///   doesn't reliably deliver key-ups that happen while ⌘ is down, and a stuck key on the remote
///   is worse than a short press. Auto-repeat then sends one pair per repeat.
/// * When ⌘ goes up, keys pressed before it and still held are released, for the same reason.
public final class KeyboardTranslator {
    public var command: CommandKey

    private struct Modifier {
        let keyCode: UInt16
        let device: UInt
        let independent: UInt
        let partner: UInt16          // the same modifier on the other side
        let isLeft: Bool
    }

    private static let modifierTable: [Modifier] = [
        Modifier(keyCode: 0x38, device: ModifierBits.leftShift, independent: ModifierBits.shift, partner: 0x3C, isLeft: true),
        Modifier(keyCode: 0x3C, device: ModifierBits.rightShift, independent: ModifierBits.shift, partner: 0x38, isLeft: false),
        Modifier(keyCode: 0x3B, device: ModifierBits.leftControl, independent: ModifierBits.control, partner: 0x3E, isLeft: true),
        Modifier(keyCode: 0x3E, device: ModifierBits.rightControl, independent: ModifierBits.control, partner: 0x3B, isLeft: false),
        Modifier(keyCode: 0x3A, device: ModifierBits.leftOption, independent: ModifierBits.option, partner: 0x3D, isLeft: true),
        Modifier(keyCode: 0x3D, device: ModifierBits.rightOption, independent: ModifierBits.option, partner: 0x3A, isLeft: false),
        Modifier(keyCode: 0x37, device: ModifierBits.leftCommand, independent: ModifierBits.command, partner: 0x36, isLeft: true),
        Modifier(keyCode: 0x36, device: ModifierBits.rightCommand, independent: ModifierBits.command, partner: 0x37, isLeft: false),
    ]

    private var held: [UInt16: String] = [:]        // non-modifier keyCode → code sent at press
    private var mods: [UInt16: String] = [:]        // modifier keyCode → code sent at press
    private var refs: [String: Int] = [:]           // remote code → physical keys holding it
    private var lastCaps: Bool?

    public init(command: CommandKey = .ctrl) { self.command = command }

    /// True while the host believes nothing is pressed.
    public var isIdle: Bool { held.isEmpty && mods.isEmpty }

    /// True while a ⌘ key is believed down.
    public var commandDown: Bool { mods[0x37] != nil || mods[0x36] != nil }

    public func remoteCode(forKeyCode kc: UInt16) -> String? {
        switch kc {
        case 0x37: return command == .ctrl ? "ControlLeft" : "MetaLeft"
        case 0x36: return command == .ctrl ? "ControlRight" : "MetaRight"
        default: return keyCodeMap[kc]
        }
    }

    public func keyDown(keyCode: UInt16, isRepeat: Bool, flags: UInt) -> [KeyEvent] {
        var out: [KeyEvent] = []
        syncModifiers(flags: flags, eventKeyCode: nil, into: &out)
        guard !KeyCodes.modifiers.contains(keyCode), let code = keyCodeMap[keyCode] else { return out }
        if let sent = held[keyCode] {
            // Auto-repeat, or a second press whose release never arrived: the host turns a
            // down for a key it holds into up+down.
            out.append(KeyEvent(sent, true))
        } else if commandDown {
            out.append(KeyEvent(code, true))
            out.append(KeyEvent(code, false))
        } else {
            held[keyCode] = code
            press(code, into: &out)
        }
        return out
    }

    public func keyUp(keyCode: UInt16, flags: UInt) -> [KeyEvent] {
        var out: [KeyEvent] = []
        if let code = held.removeValue(forKey: keyCode) { release(code, into: &out) }
        syncModifiers(flags: flags, eventKeyCode: nil, into: &out)
        return out
    }

    public func flagsChanged(keyCode: UInt16, flags: UInt) -> [KeyEvent] {
        var out: [KeyEvent] = []
        if keyCode == KeyCodes.capsLock {
            let on = flags & ModifierBits.capsLock != 0
            if lastCaps != on {
                lastCaps = on
                out.append(KeyEvent("CapsLock", true))
                out.append(KeyEvent("CapsLock", false))
            }
        }
        syncModifiers(flags: flags, eventKeyCode: keyCode, into: &out)
        return out
    }

    /// Forget every pressed key (the caller sends `rel`). Returns true if anything was held.
    @discardableResult
    public func reset() -> Bool {
        let any = !isIdle
        held.removeAll()
        mods.removeAll()
        refs.removeAll()
        return any
    }

    /// A shortcut from the toolbar: press in order, release in reverse.
    public static func combo(_ codes: [String]) -> [KeyEvent] {
        codes.map { KeyEvent($0, true) } + codes.reversed().map { KeyEvent($0, false) }
    }

    // MARK: -

    private func syncModifiers(flags: UInt, eventKeyCode: UInt16?, into out: inout [KeyEvent]) {
        let commandWasDown = commandDown
        for m in Self.modifierTable {
            var down: Bool
            if flags & m.independent == 0 {
                down = false
            } else if flags & (m.device | Self.device(of: m.partner)) != 0 {
                down = flags & m.device != 0
            } else {
                // No device bits (synthetic events): keep our belief, or take the key that changed.
                let partnerDown = mods[m.partner] != nil || eventKeyCode == m.partner
                down = mods[m.keyCode] != nil || eventKeyCode == m.keyCode || (!partnerDown && m.isLeft)
            }
            if down, mods[m.keyCode] == nil, let code = remoteCode(forKeyCode: m.keyCode) {
                mods[m.keyCode] = code
                press(code, into: &out)
            } else if !down, let code = mods.removeValue(forKey: m.keyCode) {
                release(code, into: &out)
            }
        }
        if commandWasDown && !commandDown && !held.isEmpty {
            for (kc, code) in held.sorted(by: { $0.key < $1.key }) {
                held.removeValue(forKey: kc)
                release(code, into: &out)
            }
        }
    }

    private static func device(of keyCode: UInt16) -> UInt {
        modifierTable.first { $0.keyCode == keyCode }?.device ?? 0
    }

    private func press(_ code: String, into out: inout [KeyEvent]) {
        let n = refs[code, default: 0]
        refs[code] = n + 1
        if n == 0 { out.append(KeyEvent(code, true)) }
    }

    private func release(_ code: String, into out: inout [KeyEvent]) {
        let n = refs[code, default: 0]
        if n <= 1 {
            refs.removeValue(forKey: code)
            if n == 1 { out.append(KeyEvent(code, false)) }
        } else {
            refs[code] = n - 1
        }
    }
}
