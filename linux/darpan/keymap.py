"""W3C KeyboardEvent.code  ->  Linux evdev key code (X11 keycode = evdev + 8).

Codes name *physical* key positions, so the host's own keyboard layout decides which
character a key produces — exactly like a USB keyboard plugged into the host.
"""

_LETTERS = "QWERTYUIOP ASDFGHJKL ZXCVBNM"
_LETTER_ROW_START = (16, 30, 44)


def _build():
    m = {}
    for row, start in zip(_LETTERS.split(), _LETTER_ROW_START):
        for i, ch in enumerate(row):
            m["Key" + ch] = start + i
    for i in range(1, 10):
        m["Digit%d" % i] = 1 + i
    m["Digit0"] = 11
    for i in range(1, 11):
        m["F%d" % i] = 58 + i
    m["F11"], m["F12"] = 87, 88
    for i in range(13, 25):
        m["F%d" % i] = 183 + (i - 13)
    m.update({
        "Escape": 1, "Minus": 12, "Equal": 13, "Backspace": 14, "Tab": 15,
        "BracketLeft": 26, "BracketRight": 27, "Enter": 28, "ControlLeft": 29,
        "Semicolon": 39, "Quote": 40, "Backquote": 41, "ShiftLeft": 42, "Backslash": 43,
        "Comma": 51, "Period": 52, "Slash": 53, "ShiftRight": 54, "NumpadMultiply": 55,
        "AltLeft": 56, "Space": 57, "CapsLock": 58, "NumLock": 69, "ScrollLock": 70,
        "Numpad7": 71, "Numpad8": 72, "Numpad9": 73, "NumpadSubtract": 74,
        "Numpad4": 75, "Numpad5": 76, "Numpad6": 77, "NumpadAdd": 78,
        "Numpad1": 79, "Numpad2": 80, "Numpad3": 81, "Numpad0": 82, "NumpadDecimal": 83,
        "IntlBackslash": 86, "IntlRo": 89, "KanaMode": 93, "Convert": 92, "NonConvert": 94,
        "NumpadEnter": 96, "ControlRight": 97, "NumpadDivide": 98, "PrintScreen": 99,
        "AltRight": 100, "Home": 102, "ArrowUp": 103, "PageUp": 104, "ArrowLeft": 105,
        "ArrowRight": 106, "End": 107, "ArrowDown": 108, "PageDown": 109, "Insert": 110,
        "Delete": 111, "AudioVolumeMute": 113, "AudioVolumeDown": 114, "AudioVolumeUp": 115,
        "NumpadEqual": 117, "Pause": 119, "NumpadComma": 121, "Lang1": 122, "Lang2": 123,
        "IntlYen": 124, "MetaLeft": 125, "MetaRight": 126, "ContextMenu": 127,
        "MediaTrackNext": 163, "MediaPlayPause": 164, "MediaTrackPrevious": 165,
        "MediaStop": 166,
        # Older/alternate spellings some browsers still emit
        "OSLeft": 125, "OSRight": 126, "VolumeMute": 113, "VolumeDown": 114, "VolumeUp": 115,
    })
    return m


EVDEV = _build()

# Modifiers, tracked so a lost key-up can never leave the host with a stuck modifier.
MODIFIERS = {EVDEV[k] for k in ("ShiftLeft", "ShiftRight", "ControlLeft", "ControlRight",
                                "AltLeft", "AltRight", "MetaLeft", "MetaRight")}


def x_keycode(code):
    """X11 keycode for a W3C code, or None if unknown."""
    ev = EVDEV.get(code)
    return None if ev is None else ev + 8
