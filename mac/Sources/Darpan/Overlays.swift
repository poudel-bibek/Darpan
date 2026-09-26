import AppKit

enum Palette {
    static let accent = NSColor(srgbRed: 0x5b / 255, green: 0x8c / 255, blue: 1, alpha: 1)
    static let good = NSColor(srgbRed: 0x3c / 255, green: 0xcf / 255, blue: 0x7a / 255, alpha: 1)
    static let fair = NSColor(srgbRed: 0xf2 / 255, green: 0xc1 / 255, blue: 0x4e / 255, alpha: 1)
    static let poor = NSColor(srgbRed: 1, green: 0x5f / 255, blue: 0x57 / 255, alpha: 1)
    static let muted = NSColor(srgbRed: 0x9a / 255, green: 0x9c / 255, blue: 0xa5 / 255, alpha: 1)
    static let line = NSColor(white: 1, alpha: 0.10)
}

/// Connection quality from capture→display latency (or RTT until that is known).
enum Quality {
    case unknown, good, fair, poor

    init(ms: Double?) {
        guard let ms else { self = .unknown; return }
        self = ms < 45 ? .good : ms < 110 ? .fair : .poor
    }

    var color: NSColor {
        switch self {
        case .unknown: return Palette.muted
        case .good: return Palette.good
        case .fair: return Palette.fair
        case .poor: return Palette.poor
        }
    }
}

/// Everything over the video, laid out by hand (top-left origin).
final class ViewerContentView: NSView {
    let video = VideoView(frame: .zero)
    let toolbar = ToolbarView()
    let stats = StatsView()
    let toasts = ToastStack()
    let overlay = BlockingOverlay()
    let drop = DropOverlay()
    let composition = CompositionView()
    /// Toolbar position: centre as a fraction of the width, top as a fraction of the height.
    var toolbarPosition = CGPoint(x: 0.84, y: 0.05) { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        for v in [video, stats, composition, toasts, drop, toolbar, overlay] as [NSView] { addSubview(v) }
        stats.isHidden = true
        overlay.isHidden = true
        drop.isHidden = true
        composition.isHidden = true
        toolbar.onResize = { [weak self] in self?.needsLayout = true }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let b = bounds
        video.frame = b
        toasts.frame = b
        overlay.frame = b
        drop.frame = b.insetBy(dx: 12, dy: 12)
        let s = stats.fittingSize
        stats.frame = CGRect(x: 8, y: 8, width: s.width, height: s.height)
        let t = toolbar.fittingSize
        let x = min(max(6, (b.width * toolbarPosition.x - t.width / 2).rounded()), max(6, b.width - t.width - 6))
        let y = min(max(6, (b.height * toolbarPosition.y).rounded()), max(6, b.height - t.height - 6))
        toolbar.frame = CGRect(x: x, y: y, width: t.width, height: t.height)
        if !composition.isHidden {
            let c = composition.fittingSize, o = video.markedTextOrigin
            composition.frame = CGRect(x: min(max(4, o.x), max(4, b.width - c.width - 4)),
                                       y: min(max(4, o.y), max(4, b.height - c.height - 4)), width: c.width, height: c.height)
        }
    }
}

// MARK: - toolbar

/// A small floating capsule, top right by default (clear of the notch and of window buttons on
/// the remote screen); pointing at it (or clicking) expands it into a row of buttons, and
/// panels open as popovers below it. Drag it by its grip to put it anywhere.
final class ToolbarView: NSView {
    enum Item: Int, CaseIterable {
        case fullScreen, display, keys, clipboard, upload, sound, stats, disconnect

        var symbol: String {
            switch self {
            case .fullScreen: return "arrow.up.left.and.arrow.down.right"
            case .display: return "display"
            case .keys: return "keyboard"
            case .clipboard: return "doc.on.clipboard"
            case .upload: return "square.and.arrow.up"
            case .sound: return "speaker.wave.2"
            case .stats: return "chart.bar"
            case .disconnect: return "power"
            }
        }

        var tip: String {
            switch self {
            case .fullScreen: return "Full screen (⌃⌥⌘F)"
            case .display: return "Display & quality"
            case .keys: return "Keyboard"
            case .clipboard: return "Clipboard"
            case .upload: return "Send files to the remote computer"
            case .sound: return "Sound"
            case .stats: return "Connection stats"
            case .disconnect: return "Disconnect (⌃⌥⌘D)"
            }
        }
    }

    var onAction: ((Item, NSButton) -> Void)?
    /// The user dragged the toolbar: new centre x and top y, as fractions of the window.
    var onMove: ((CGPoint) -> Void)?
    var onMoveEnded: (() -> Void)?
    var onResize: (() -> Void)?

    var quality: Quality = .unknown {
        didSet {
            guard quality != oldValue else { return }
            pillDot.layer?.backgroundColor = quality.color.cgColor
            barDot.layer?.backgroundColor = quality.color.cgColor
        }
    }
    var statsOn = false { didSet { buttons[.stats]?.state = statsOn ? .on : .off } }
    var soundOn = true {
        didSet {
            let b = buttons[.sound]
            b?.image = NSImage(systemSymbolName: soundOn ? "speaker.wave.2" : "speaker.slash", accessibilityDescription: "Sound")
            b?.toolTip = soundOn ? "Sound on (click to mute)" : "Sound off"
        }
    }
    var isFullScreen = false {
        didSet {
            let name = isFullScreen ? "arrow.down.right.and.arrow.up.left" : Item.fullScreen.symbol
            buttons[.fullScreen]?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Full screen")
            buttons[.fullScreen]?.toolTip = isFullScreen ? "Exit full screen (⌃⌥⌘F)" : Item.fullScreen.tip
        }
    }
    /// The panel shown as a popover, if any: its button stays highlighted and the bar open.
    var openPanel: Item? {
        didSet {
            for i in [Item.display, .keys, .clipboard] { buttons[i]?.state = openPanel == i ? .on : .off }
            if openPanel == nil && !hovering { collapse(after: 0.6) }
        }
    }
    private(set) var expanded = false

    private let pill = NSView()
    private let pillDot = NSView()
    private let bar = NSVisualEffectView()
    private let barDot = NSView()
    private var buttons: [Item: NSButton] = [:]
    private var hovering = false
    private var collapseTimer: Timer?
    private var drag: (start: CGPoint, grab: CGPoint, moved: Bool)?     // window point, offset of the grab in self

    init() {
        super.init(frame: .zero)
        setUpPill()
        setUpBar()
        bar.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize { expanded ? bar.fittingSize : NSSize(width: 44, height: 22) }

    override func layout() {
        super.layout()
        pill.frame = CGRect(x: 0, y: 0, width: 44, height: 22)
        pillDot.frame = CGRect(x: 26, y: 8, width: 6, height: 6)
        bar.frame = bounds
    }

    private func setUpPill() {
        pill.wantsLayer = true
        let l = pill.layer!
        l.backgroundColor = NSColor(srgbRed: 18 / 255, green: 20 / 255, blue: 24 / 255, alpha: 0.62).cgColor
        l.cornerRadius = 11
        l.borderWidth = 1
        l.borderColor = Palette.line.cgColor
        pill.alphaValue = 0.6
        pill.toolTip = "Drag to move · point at it for the toolbar"
        let grip = GripView(frame: CGRect(x: 10, y: 6, width: 8, height: 10))
        for dot in [pillDot, barDot] {
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = quality.color.cgColor
        }
        pill.addSubview(pillDot)
        pill.addSubview(grip)
        addSubview(pill)
    }

    private func setUpBar() {
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.appearance = NSAppearance(named: .darkAqua)
        bar.maskImage = Self.rounded(radius: 12)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 6)
        let barGrip = GripView(frame: .zero)
        barGrip.toolTip = "Drag to move"
        barGrip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([barGrip.widthAnchor.constraint(equalToConstant: 8),
                                     barGrip.heightAnchor.constraint(equalToConstant: 10)])
        stack.addArrangedSubview(barGrip)
        stack.setCustomSpacing(8, after: barGrip)
        stack.translatesAutoresizingMaskIntoConstraints = false
        barDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([barDot.widthAnchor.constraint(equalToConstant: 6),
                                     barDot.heightAnchor.constraint(equalToConstant: 6)])
        stack.addArrangedSubview(barDot)
        stack.setCustomSpacing(8, after: barDot)
        for item in Item.allCases {
            if item == .disconnect {
                let sep = NSBox()
                sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.heightAnchor.constraint(equalToConstant: 20).isActive = true
                stack.addArrangedSubview(sep)
            }
            let b = NSButton(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.tip)!,
                             target: self, action: #selector(clicked(_:)))
            b.bezelStyle = .recessed
            b.setButtonType(.pushOnPushOff)
            b.showsBorderOnlyWhileMouseInside = true
            b.refusesFirstResponder = true
            b.contentTintColor = item == .disconnect ? Palette.poor : .white
            b.toolTip = item.tip
            b.tag = item.rawValue
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 36),
                                         b.heightAnchor.constraint(equalToConstant: 32)])
            buttons[item] = b
            stack.addArrangedSubview(b)
        }
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor), stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        addSubview(bar)
    }

    @objc private func clicked(_ b: NSButton) {
        guard let item = Item(rawValue: b.tag) else { return }
        // Toggle-looking buttons show state only where it means something.
        switch item {
        case .stats: b.state = statsOn ? .on : .off
        case .display, .keys, .clipboard: b.state = openPanel == item ? .on : .off
        default: b.state = .off
        }
        onAction?(item, b)
    }

    func button(_ item: Item) -> NSButton? { buttons[item] }

    func expand() {
        collapseTimer?.invalidate()
        guard !expanded else { return }
        expanded = true
        pill.isHidden = true
        bar.isHidden = false
        onResize?()
    }

    func collapse(after delay: TimeInterval) {
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.openPanel == nil, !self.hovering, self.drag == nil else { return }
            self.expanded = false
            self.pill.isHidden = false
            self.bar.isHidden = true
            self.onResize?()
        }
    }

    // MARK: hover and drag

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with e: NSEvent) {
        hovering = true
        pill.alphaValue = 1
        if drag == nil { expand() }
    }

    override func mouseExited(with e: NSEvent) {
        hovering = false
        pill.alphaValue = 0.6
        if openPanel == nil { collapse(after: 0.6) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        drag = (e.locationInWindow, convert(e.locationInWindow, from: nil), false)
    }

    override func mouseDragged(with e: NSEvent) {
        guard var d = drag, let sv = superview, sv.bounds.width > 0, sv.bounds.height > 0 else { return }
        if hypot(e.locationInWindow.x - d.start.x, e.locationInWindow.y - d.start.y) > 4 { d.moved = true }
        drag = d
        guard d.moved else { return }
        let p = sv.convert(e.locationInWindow, from: nil)               // superview is flipped: y from the top
        let centreX = p.x - d.grab.x + bounds.width / 2
        let top = p.y - d.grab.y
        onMove?(CGPoint(x: min(1, max(0, centreX / sv.bounds.width)), y: min(1, max(0, top / sv.bounds.height))))
    }

    override func mouseUp(with e: NSEvent) {
        let moved = drag?.moved ?? false
        drag = nil
        if moved { onMoveEnded?() } else { expand() }
    }

    /// A mask for NSVisualEffectView: rounded on every side.
    private static func rounded(radius r: CGFloat) -> NSImage {
        let side = r * 2 + 2
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }
}

/// Six dots: the handle to drag the toolbar by (the drag itself is handled by ToolbarView).
private final class GripView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.5).setFill()
        for col in 0..<2 { for row in 0..<3 {
            NSBezierPath(ovalIn: NSRect(x: CGFloat(col) * 4 + 1, y: CGFloat(row) * 4 + 1, width: 2, height: 2)).fill()
        } }
    }
}

// MARK: - small overlays

/// Monospaced connection stats, top left. Clicks go through to the video.
final class StatsView: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.62).cgColor
        layer?.cornerRadius = 9
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = NSColor(srgbRed: 0xd6 / 255, green: 0xd8 / 255, blue: 0xde / 255, alpha: 1)
        label.maximumNumberOfLines = 0
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    var text: String {
        get { label.stringValue }
        set {
            guard newValue != label.stringValue else { return }
            let resize = label.fittingSize
            label.stringValue = newValue
            if label.fittingSize != resize { superview?.needsLayout = true }
            needsLayout = true
        }
    }

    override var fittingSize: NSSize {
        let s = label.fittingSize
        return NSSize(width: ceil(s.width) + 18, height: ceil(s.height) + 14)
    }

    override func layout() {
        super.layout()
        label.frame = bounds.inset(9, 7)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Short messages at the bottom centre. Clicks go through to the video.
final class ToastStack: NSView {
    final class Toast: NSView {
        fileprivate let label = NSTextField(wrappingLabelWithString: "")
        fileprivate var timer: Timer?

        init(error: Bool) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor(srgbRed: 28 / 255, green: 30 / 255, blue: 35 / 255, alpha: 0.96).cgColor
            layer?.cornerRadius = 11
            layer?.borderWidth = 1
            layer?.borderColor = (error ? Palette.poor.withAlphaComponent(0.6) : Palette.line).cgColor
            label.font = .systemFont(ofSize: 13)
            label.textColor = NSColor(white: 0.92, alpha: 1)
            label.isSelectable = false
            addSubview(label)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override var isFlipped: Bool { true }

        func size(maxWidth: CGFloat) -> NSSize {
            label.preferredMaxLayoutWidth = maxWidth - 28
            let s = label.fittingSize
            return NSSize(width: min(maxWidth, ceil(s.width) + 28), height: ceil(s.height) + 20)
        }

        override func layout() {
            super.layout()
            label.frame = bounds.inset(14, 10)
        }
    }

    private var toasts: [Toast] = []

    override var isFlipped: Bool { true }

    /// `ttl` nil: stays until removed.
    @discardableResult
    func show(_ text: String, error: Bool = false, ttl: TimeInterval? = 3.5) -> Toast {
        let t = Toast(error: error)
        t.label.stringValue = text
        toasts.append(t)
        addSubview(t)
        if let ttl { expire(t, after: ttl) }
        needsLayout = true
        return t
    }

    func update(_ t: Toast, text: String) {
        guard t.label.stringValue != text else { return }
        t.label.stringValue = text
        needsLayout = true
    }

    func expire(_ t: Toast, after ttl: TimeInterval) {
        t.timer?.invalidate()
        t.timer = Timer.scheduledTimer(withTimeInterval: ttl, repeats: false) { [weak self, weak t] _ in
            if let t { self?.remove(t) }
        }
    }

    func remove(_ t: Toast) {
        t.timer?.invalidate()
        toasts.removeAll { $0 === t }
        t.removeFromSuperview()
        needsLayout = true
    }

    func removeAll() { toasts.forEach(remove) }

    override func layout() {
        super.layout()
        var y = bounds.height - 18
        let maxWidth = min(460, bounds.width * 0.94)
        for t in toasts.reversed() {
            let s = t.size(maxWidth: maxWidth)
            y -= s.height
            t.frame = CGRect(x: ((bounds.width - s.width) / 2).rounded(), y: y, width: s.width, height: s.height)
            y -= 8
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// "Reconnecting…" over a dimmed picture; swallows clicks.
final class BlockingOverlay: NSView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        spinner.style = .spinning
        spinner.appearance = NSAppearance(named: .darkAqua)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .white
        label.alignment = .center
        addSubview(spinner)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func show(_ text: String) {
        label.stringValue = text
        isHidden = false
        spinner.startAnimation(nil)
        needsLayout = true
    }

    func hide() {
        isHidden = true
        spinner.stopAnimation(nil)
    }

    override func layout() {
        super.layout()
        let l = label.fittingSize
        spinner.frame = CGRect(x: ((bounds.width - 32) / 2).rounded(), y: (bounds.height / 2 - 36).rounded(), width: 32, height: 32)
        label.frame = CGRect(x: 0, y: (bounds.height / 2 + 10).rounded(), width: bounds.width, height: ceil(l.height))
    }

    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

/// Dashed outline while files are dragged over the window.
final class DropOverlay: NSView {
    private let border = CAShapeLayer()
    private let label = NSTextField(labelWithString: "Drop files to send them to the remote computer")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Palette.accent.withAlphaComponent(0.10).cgColor
        layer?.cornerRadius = 18
        border.fillColor = nil
        border.strokeColor = Palette.accent.cgColor
        border.lineWidth = 2
        border.lineDashPattern = [8, 6]
        layer?.addSublayer(border)
        label.font = .systemFont(ofSize: 16)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        border.frame = bounds
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 17, cornerHeight: 17, transform: nil)
        let h = ceil(label.fittingSize.height)
        label.frame = CGRect(x: 0, y: ((bounds.height - h) / 2).rounded(), width: bounds.width, height: h)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The input method's text being composed, near the pointer.
final class CompositionView: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 28 / 255, green: 30 / 255, blue: 35 / 255, alpha: 0.96).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = Palette.accent.cgColor
        label.font = .systemFont(ofSize: 15)
        label.textColor = .white
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var text: String {
        get { label.stringValue }
        set {
            label.attributedStringValue = NSAttributedString(string: newValue, attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue, .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: NSColor.white,
            ])
        }
    }

    override var fittingSize: NSSize {
        let s = label.fittingSize
        return NSSize(width: ceil(s.width) + 16, height: ceil(s.height) + 8)
    }

    override func layout() {
        super.layout()
        label.frame = bounds.inset(8, 4)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private extension CGRect {
    /// Like insetBy, but never the (infinite) null rectangle when the view is still tiny.
    func inset(_ dx: CGFloat, _ dy: CGFloat) -> CGRect {
        CGRect(x: minX + dx, y: minY + dy, width: max(0, width - 2 * dx), height: max(0, height - 2 * dy))
    }
}
