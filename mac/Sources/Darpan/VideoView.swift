import AppKit
import AVFoundation
import CoreMedia
import DarpanCore

/// What the video view needs from its session.
protocol VideoViewDelegate: AnyObject {
    /// Sends a message if signed in.
    func send(_ message: String?)
    /// A key event the input method didn't turn into text: send the key itself.
    func videoView(_ view: VideoView, rawKey event: NSEvent)
    /// Text committed by an input method, dictation or the emoji picker.
    func videoView(_ view: VideoView, typed text: String)
    func videoView(_ view: VideoView, dropped files: [URL])
    func videoViewPointerDown(_ view: VideoView)
    func videoViewMarkedTextChanged(_ view: VideoView)
    var canAcceptFiles: Bool { get }
}

/// The remote screen. Decoded frames go from VideoToolbox's output thread straight into an
/// AVSampleBufferDisplayLayer: nothing happens on the main thread per frame. Mouse, scroll,
/// cursor and file drops are handled here; keys come from KeyboardCapture, which runs them
/// through this view's input context when an input method (Chinese, Japanese…) is active.
final class VideoView: NSView, VideoSink {
    weak var delegate: VideoViewDelegate?

    /// Stream pixels; pointer coordinates are sent in this space.
    var streamSize: CGSize = .zero {
        didSet { if streamSize != oldValue { lastSent = nil; needsLayout = true } }
    }
    var scaleMode: ScaleMode = .fit { didSet { if scaleMode != oldValue { needsLayout = true } } }
    var wheel = WheelAccumulator()
    /// The video rectangle in view coordinates (top-left origin).
    private(set) var videoRect: CGRect = .zero

    private let surface = DisplaySurface()
    private var displayLayer: AVSampleBufferDisplayLayer { surface.displayLayer }
    private let renderLock = NSLock()
    private var format: CMVideoFormatDescription?          // renderLock
    private var pointer: CGPoint?                           // last position, for panning in Actual size
    private var lastSent: (x: Int, y: Int)?
    private(set) var buttonsDown = Set<Int>()
    private var cursorImages: [Int: Client.Cursor] = [:]  // as sent: host pixels
    private var cursors: [Int: NSCursor] = [:]           // at `cursorScale`
    private var cursorScale: CGFloat = 0
    private var cursorId = -1
    private var cursor = NSCursor.arrow
    private var tracking: NSTrackingArea?

    // Input method state (NSTextInputClient)
    private var interpreting: NSEvent?
    private(set) var markedText = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(surface)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override var isOpaque: Bool { true }

    // MARK: - frames (VideoToolbox thread)

    func display(_ image: CVImageBuffer) {
        renderLock.lock()
        defer { renderLock.unlock() }
        #if DEBUG
        if keepLastFrame { lastFrame = image }
        #endif
        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: image) {
            format = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                                                         formatDescriptionOut: &format)
        }
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let r = displayLayer.sampleBufferRenderer
        if r.status == .failed { r.flush() }
        r.enqueue(sample)
    }

    /// Blank the picture (session over).
    func clear() {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        cursorImages.removeAll()
        cursors.removeAll()
        cursorId = -1
        setCursor(.arrow)
    }

    #if DEBUG
    var keepLastFrame = DebugHooks.enabled
    private var lastFrame: CVImageBuffer?               // renderLock
    var debugLastFrame: CVImageBuffer? {
        renderLock.lock(); defer { renderLock.unlock() }
        return lastFrame
    }
    #endif

    // MARK: - geometry

    override func layout() {
        super.layout()
        relayout()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    private func relayout() {
        let r = VideoGeometry.videoRect(mode: scaleMode, stream: streamSize, bounds: bounds.size,
                                        backingScale: window?.backingScaleFactor ?? 2, pointer: pointer)
        guard r != videoRect || surface.frame != r else { return }
        videoRect = r
        surface.frame = r
        window?.invalidateCursorRects(for: self)
        if cursorId > 0, abs(pointsPerPixel - cursorScale) > 0.001 { showCursor(cursorId) }
    }

    /// View points per stream pixel.
    private var pointsPerPixel: CGFloat {
        streamSize.width > 0 && videoRect.width > 0 ? videoRect.width / streamSize.width : 1
    }

    /// Device pixels of the view, for picking a remote resolution that fills it.
    var pixelSize: CGSize {
        let s = window?.backingScaleFactor ?? 2
        return CGSize(width: bounds.width * s, height: bounds.height * s)
    }

    // MARK: - pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with e: NSEvent) { move(e) }
    override func mouseDragged(with e: NSEvent) { move(e) }
    override func rightMouseDragged(with e: NSEvent) { move(e) }
    override func otherMouseDragged(with e: NSEvent) { move(e) }
    override func mouseDown(with e: NSEvent) { button(e, down: true) }
    override func mouseUp(with e: NSEvent) { button(e, down: false) }
    override func rightMouseDown(with e: NSEvent) { button(e, down: true) }
    override func rightMouseUp(with e: NSEvent) { button(e, down: false) }
    override func otherMouseDown(with e: NSEvent) { button(e, down: true) }
    override func otherMouseUp(with e: NSEvent) { button(e, down: false) }
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func scrollWheel(with e: NSEvent) {
        guard let d = wheel.add(deltaX: Double(e.scrollingDeltaX), deltaY: Double(e.scrollingDeltaY),
                                precise: e.hasPreciseScrollingDeltas) else { return }
        delegate?.send(Msg.wh(dx: d.dx, dy: d.dy))
    }

    /// Sends the pointer position if it changed. AppKit already coalesces moves to about one
    /// per display frame, so each one goes out at once.
    private func move(_ e: NSEvent) {
        guard streamSize.width > 0 else { return }
        let p = convert(e.locationInWindow, from: nil)
        pointer = p
        if scaleMode == .actual { relayout() }
        let s = VideoGeometry.streamPoint(p, videoRect: videoRect, streamWidth: Int(streamSize.width),
                                          streamHeight: Int(streamSize.height))
        if let l = lastSent, l == s { return }
        lastSent = s
        delegate?.send(Msg.mm(s.x, s.y))
    }

    private func button(_ e: NSEvent, down: Bool) {
        if down {
            delegate?.videoViewPointerDown(self)
            if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        }
        let number: Int
        switch e.type {
        case .leftMouseDown, .leftMouseUp: number = 0
        case .rightMouseDown, .rightMouseUp: number = 1
        default: number = e.buttonNumber
        }
        guard let b = protocolButton(number) else { return }
        move(e)
        if down { buttonsDown.insert(b) } else if buttonsDown.remove(b) == nil { return }
        delegate?.send(Msg.mb(b, down))
    }

    /// Forget pressed buttons (the caller sends `rel`).
    func releaseButtons() -> Bool {
        defer { buttonsDown.removeAll() }
        return !buttonsDown.isEmpty
    }

    /// Where the pointer is, in screen coordinates (for the input method's candidate window).
    private var pointerOnScreen: NSRect {
        guard let window else { return .zero }
        let p = pointer ?? CGPoint(x: videoRect.midX, y: videoRect.maxY - 40)
        return window.convertToScreen(convert(NSRect(x: p.x, y: p.y + 4, width: 1, height: 18), to: nil))
    }

    var markedTextOrigin: CGPoint {
        pointer.map { CGPoint(x: $0.x, y: $0.y + 24) } ?? CGPoint(x: videoRect.midX, y: videoRect.maxY - 40)
    }

    // MARK: - cursor

    /// The host sends each image once per session, later only its id (PROTOCOL.md §4).
    func setCursor(_ c: Client.Cursor) {
        if c.png != nil, c.width > 0, c.height > 0 {
            cursorImages[c.id] = c
            cursors[c.id] = nil
        }
        showCursor(c.id)
    }

    /// Image and hotspot scaled like the video (PROTOCOL.md §4), but never smaller than 12 pt
    /// tall: a 4K screen fit into a small window would otherwise leave an unusable pointer.
    private func showCursor(_ id: Int) {
        cursorId = id
        guard id != 0 else { return setCursor(Self.hiddenCursor) }
        let scale = pointsPerPixel
        if scale != cursorScale {
            cursors.removeAll()
            cursorScale = scale
        }
        if cursors[id] == nil, let c = cursorImages[id], let png = c.png, let image = NSImage(data: png) {
            let k = max(scale, 12 / CGFloat(c.height))
            image.size = NSSize(width: CGFloat(c.width) * k, height: CGFloat(c.height) * k)
            cursors[id] = NSCursor(image: image, hotSpot: NSPoint(x: CGFloat(c.hotX) * k, y: CGFloat(c.hotY) * k))
        }
        setCursor(cursors[id] ?? .arrow)
    }

    private func setCursor(_ c: NSCursor) {
        cursor = c
        window?.invalidateCursorRects(for: self)
        if let window, window.isKeyWindow,
           videoRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            c.set()
        }
    }

    override func resetCursorRects() {
        let r = videoRect.intersection(visibleRect)
        if !r.isEmpty { addCursorRect(r, cursor: cursor) }
    }

    private static let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true },
                                               hotSpot: .zero)

    // MARK: - keys that reach the view (keyboard capture released)

    var keyHandler: ((NSEvent) -> Void)?
    override func keyDown(with e: NSEvent) { keyHandler?(e) }
    override func keyUp(with e: NSEvent) { keyHandler?(e) }
    override func flagsChanged(with e: NSEvent) { keyHandler?(e) }

    /// Runs a key press through the input method. Keys it doesn't turn into text are sent as keys.
    func interpret(_ e: NSEvent) {
        interpreting = e
        let handled = inputContext?.handleEvent(e) ?? false
        if !handled, let pending = interpreting { delegate?.videoView(self, rawKey: pending) }
        interpreting = nil
    }

    func cancelComposition() {
        guard !markedText.isEmpty else { return }
        inputContext?.discardMarkedText()
        setMarked("")
    }

    private func setMarked(_ s: String) {
        guard s != markedText else { return }
        markedText = s
        delegate?.videoViewMarkedTextChanged(self)
    }

    // MARK: - file drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard delegate?.canAcceptFiles == true, !fileURLs(sender).isEmpty else { return [] }
        dropHighlight?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight?(false)
        let urls = fileURLs(sender)
        guard !urls.isEmpty, delegate?.canAcceptFiles == true else { return false }
        delegate?.videoView(self, dropped: urls)
        return true
    }

    var dropHighlight: ((Bool) -> Void)?

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

// MARK: - NSTextInputClient (input methods, dictation, emoji picker)

extension VideoView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let composing = !markedText.isEmpty
        setMarked("")
        if let e = interpreting, !composing, s == e.characters {
            interpreting = nil
            delegate?.videoView(self, rawKey: e)          // plain typing: send the key, not text
        } else if !s.isEmpty {
            interpreting = nil
            delegate?.videoView(self, typed: s)
        }
    }

    override func doCommand(by selector: Selector) {
        // Return, Backspace, arrows… while not composing: the key itself.
        if let e = interpreting {
            interpreting = nil
            delegate?.videoView(self, rawKey: e)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        setMarked((string as? NSAttributedString)?.string ?? (string as? String) ?? "")
        interpreting = nil
    }

    func unmarkText() {
        let s = markedText
        setMarked("")
        if !s.isEmpty { delegate?.videoView(self, typed: s) }
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count)
    }

    func selectedRange() -> NSRange { NSRange(location: markedText.utf16.count, length: 0) }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { pointerOnScreen }
}

/// The view whose backing layer shows the video, sized to the video rectangle.
private final class DisplaySurface: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        displayLayer.videoGravity = .resize            // the frame already has the stream's aspect ratio
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.preventsDisplaySleepDuringVideoPlayback = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer { displayLayer }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
