import AppKit

enum OverlayAction {
    case edit, copy, save
}

/// Full-screen window showing the frozen screen image with a dim layer; the user drags out a rectangle.
final class OverlayWindow: NSWindow {
    let screenImage: CGImage
    let scale: CGFloat

    init(screen: NSScreen, image: CGImage) {
        screenImage = image
        scale = CGFloat(image.width) / screen.frame.width
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = true
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image, scale: scale)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
    // MARK: State

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum Drag {
        case none
        case creating(anchor: NSPoint)
        case moving(last: NSPoint)
        case resizing(Handle, base: NSRect)
    }

    private struct ActionButton {
        let symbol: String
        let action: OverlayAction?   // nil = cancel
    }

    private let cgImage: CGImage
    private let nsImage: NSImage
    private let scale: CGFloat

    private var selection: NSRect?
    private var drag: Drag = .none
    private var mouse: NSPoint?
    private var hoveredButton: Int?

    private var hasSelection: Bool {
        guard let selection else { return false }
        return selection.width >= 1 && selection.height >= 1
    }

    private var isSettled: Bool {
        if case .none = drag { return hasSelection }
        return false
    }

    private var showsPrecisionAids: Bool {
        switch drag {
        case .none: return !hasSelection
        case .creating, .resizing: return true
        case .moving: return false
        }
    }

    // MARK: Style

    private let dimAlpha: CGFloat = 0.5
    private let handleSize: CGFloat = 8
    private let handleHitRadius: CGFloat = 10
    private let loupePixels = 15
    private let pointsPerPixel: CGFloat = 8
    private let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private let pillPadding = NSSize(width: 9, height: 5)
    private let swatchWidth: CGFloat = 12
    private let buttonSize: CGFloat = 30
    private let barPadding: CGFloat = 5

    private let buttons: [ActionButton] = [
        ActionButton(symbol: "doc.on.doc", action: .copy),
        ActionButton(symbol: "square.and.arrow.down", action: .save),
        ActionButton(symbol: "pencil", action: .edit),
        ActionButton(symbol: "xmark", action: nil),
    ]
    private lazy var buttonImages: [NSImage] = buttons.map { button in
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let symbol = NSImage(systemSymbolName: button.symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(config)!
        return NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    // MARK: Init

    init(frame: NSRect, image: CGImage, scale: CGFloat) {
        cgImage = image
        self.scale = scale
        nsImage = NSImage(cgImage: image, size: frame.size)
        super.init(frame: frame)
        // .activeAlways delivers mouseMoved even when this window isn't key (multi-display).
        addTrackingArea(NSTrackingArea(rect: frame, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    private func finish(_ action: OverlayAction) {
        AppDelegate.shared.overlayFinished(window: window as? OverlayWindow, localRect: selection, action: action)
    }

    private func cancel() {
        AppDelegate.shared.overlayFinished(window: nil, localRect: nil)
    }

    // MARK: Geometry helpers

    private func rect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Rectangle for a create-drag. Shift = square, Option = grow from the anchor outwards.
    private func creationRect(anchor: NSPoint, to p: NSPoint, flags: NSEvent.ModifierFlags) -> NSRect {
        var dx = p.x - anchor.x
        var dy = p.y - anchor.y
        if flags.contains(.shift) {
            let side = max(abs(dx), abs(dy))
            dx = side * (dx < 0 ? -1 : 1)
            dy = side * (dy < 0 ? -1 : 1)
        }
        if flags.contains(.option) {
            return NSRect(x: anchor.x - abs(dx), y: anchor.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
        }
        return rect(anchor, NSPoint(x: anchor.x + dx, y: anchor.y + dy))
    }

    private func resized(_ base: NSRect, handle: Handle, to p: NSPoint) -> NSRect {
        var minX = base.minX, maxX = base.maxX, minY = base.minY, maxY = base.maxY
        switch handle {
        case .left, .topLeft, .bottomLeft: minX = p.x
        case .right, .topRight, .bottomRight: maxX = p.x
        default: break
        }
        switch handle {
        case .top, .topLeft, .topRight: maxY = p.y
        case .bottom, .bottomLeft, .bottomRight: minY = p.y
        default: break
        }
        return NSRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    private func clampedToBounds(_ r: NSRect) -> NSRect {
        var r = r
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    private func handlePoint(_ handle: Handle, of r: NSRect) -> NSPoint {
        switch handle {
        case .topLeft: return NSPoint(x: r.minX, y: r.maxY)
        case .top: return NSPoint(x: r.midX, y: r.maxY)
        case .topRight: return NSPoint(x: r.maxX, y: r.maxY)
        case .right: return NSPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return NSPoint(x: r.maxX, y: r.minY)
        case .bottom: return NSPoint(x: r.midX, y: r.minY)
        case .bottomLeft: return NSPoint(x: r.minX, y: r.minY)
        case .left: return NSPoint(x: r.minX, y: r.midY)
        }
    }

    private func handle(at p: NSPoint) -> Handle? {
        guard let selection, hasSelection else { return nil }
        return Handle.allCases.first { handle in
            let hp = handlePoint(handle, of: selection)
            return abs(hp.x - p.x) <= handleHitRadius && abs(hp.y - p.y) <= handleHitRadius
        }
    }

    private func cursor(for handle: Handle) -> NSCursor {
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }

    // MARK: Action bar geometry

    private var barSize: NSSize {
        NSSize(width: CGFloat(buttons.count) * buttonSize + barPadding * 2 + CGFloat(buttons.count - 1) * 2,
               height: buttonSize + barPadding * 2)
    }

    private func barRect(for selection: NSRect) -> NSRect {
        let size = barSize
        var origin = NSPoint(x: selection.maxX - size.width, y: selection.minY - 10 - size.height)
        if origin.y < bounds.minY + 4 {
            origin.y = selection.maxY + 10
            if origin.y + size.height > bounds.maxY - 4 {
                origin.y = selection.minY + 10          // inside, bottom-right
                origin.x = selection.maxX - size.width - 10
            }
        }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 4)
        return NSRect(origin: origin, size: size)
    }

    private func buttonRect(_ index: Int, in bar: NSRect) -> NSRect {
        NSRect(x: bar.minX + barPadding + CGFloat(index) * (buttonSize + 2),
               y: bar.minY + barPadding, width: buttonSize, height: buttonSize)
    }

    private func buttonIndex(at p: NSPoint) -> Int? {
        guard isSettled, let selection else { return nil }
        let bar = barRect(for: selection)
        return buttons.indices.first { buttonRect($0, in: bar).contains(p) }
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
    }

    override func mouseExited(with event: NSEvent) {
        if case .none = drag {
            mouse = nil
            needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        hoveredButton = buttonIndex(at: p)
        updateCursor(at: p)
        needsDisplay = true
    }

    private func updateCursor(at p: NSPoint) {
        guard isSettled, let selection else { NSCursor.crosshair.set(); return }
        if hoveredButton != nil { NSCursor.arrow.set() }
        else if let h = handle(at: p) { cursor(for: h).set() }
        else if selection.contains(p) { NSCursor.openHand.set() }
        else { NSCursor.crosshair.set() }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let p = convert(event.locationInWindow, from: nil)
        mouse = p

        if isSettled, let selection {
            if let index = buttonIndex(at: p) {
                if let action = buttons[index].action { finish(action) } else { cancel() }
                return
            }
            if event.clickCount == 2, selection.contains(p) {
                finish(.edit)
                return
            }
            if let h = handle(at: p) {
                drag = .resizing(h, base: selection)
                needsDisplay = true
                return
            }
            if selection.contains(p) {
                drag = .moving(last: p)
                NSCursor.closedHand.set()
                return
            }
        }
        selection = NSRect(origin: p, size: .zero)
        drag = .creating(anchor: p)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        switch drag {
        case .creating(let anchor):
            selection = creationRect(anchor: anchor, to: p, flags: event.modifierFlags).integral
        case .moving(let last):
            if let current = selection {
                selection = clampedToBounds(current.offsetBy(dx: p.x - last.x, dy: p.y - last.y)).integral
            }
            drag = .moving(last: p)
        case .resizing(let handle, let base):
            selection = resized(base, handle: handle, to: p).integral
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .creating = drag, !hasSelection {
            selection = nil
        } else if let current = selection, current.width < 2 || current.height < 2 {
            selection = nil
        }
        drag = .none
        if let mouse { hoveredButton = buttonIndex(at: mouse); updateCursor(at: mouse) }
        needsDisplay = true
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "c": if hasSelection { finish(.copy) }; return
            case "s": if hasSelection { finish(.save) }; return
            case "e": if hasSelection { finish(.edit) }; return
            default: return
            }
        }

        switch event.keyCode {
        case 53:                               // Esc
            cancel()
        case 36, 76:                           // Return / Enter
            if hasSelection { finish(.edit) }
        case 123, 124, 125, 126:               // arrows: nudge
            guard hasSelection, let current = selection else { return }
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let delta: (CGFloat, CGFloat)
            switch event.keyCode {
            case 123: delta = (-step, 0)
            case 124: delta = (step, 0)
            case 125: delta = (0, -step)
            default: delta = (0, step)
            }
            selection = clampedToBounds(current.offsetBy(dx: delta.0, dy: delta.1))
            needsDisplay = true
        default:
            break
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        nsImage.draw(in: bounds)
        NSColor.black.withAlphaComponent(dimAlpha).setFill()
        bounds.fill()

        if let selection, hasSelection {
            let hint = isSettled ? settledHint : creatingHint
            drawSelection(selection, avoiding: hintRect(hint))
            if isSettled { drawActionBar(for: selection) }
            drawHint(hint)
        } else {
            drawHint(idleHint)
        }

        if showsPrecisionAids, let mouse {
            drawGuides(at: mouse)
            drawLoupe(at: mouse)
        }
    }

    private let idleHint = "Drag to select an area   ·   ⇧ square   ·   ⌥ from center   ·   Esc to cancel"
    private let creatingHint = "⇧ square   ·   ⌥ from center"
    private let settledHint = "⏎ Edit   ·   ⌘C Copy   ·   ⌘S Save   ·   Drag edges to adjust   ·   Esc Cancel"

    private func drawSelection(_ selection: NSRect, avoiding hint: NSRect) {
        nsImage.draw(in: selection, from: selection, operation: .copy, fraction: 1)

        NSColor.black.withAlphaComponent(0.55).setStroke()
        stroke(NSBezierPath(rect: selection.insetBy(dx: -1.5, dy: -1.5)))
        NSColor.white.setStroke()
        stroke(NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5)))

        // Handles: corners always, edge midpoints once the selection is big enough to grab them apart.
        let showEdges = selection.width > 40 && selection.height > 40
        for handle in Handle.allCases {
            let isCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(handle)
            guard isCorner || showEdges else { continue }
            let c = handlePoint(handle, of: selection)
            let r = NSRect(x: c.x - handleSize / 2, y: c.y - handleSize / 2, width: handleSize, height: handleSize)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor.black.withAlphaComponent(0.55).setStroke()
            stroke(NSBezierPath(ovalIn: r.insetBy(dx: -0.5, dy: -0.5)))
        }

        // Size readout in real pixels; pick the first spot that fits and doesn't hit the action bar.
        let text = "\(Int(selection.width * scale)) × \(Int(selection.height * scale))"
        let size = pillSize(for: text)
        let bar = isSettled ? barRect(for: selection) : .null
        let candidates = [
            NSPoint(x: selection.minX, y: selection.maxY + 8),
            NSPoint(x: selection.minX, y: selection.minY - size.height - 8),
            NSPoint(x: selection.minX + 8, y: selection.maxY - size.height - 8),
        ]
        let origin = candidates.first { candidate in
            let r = NSRect(origin: candidate, size: size)
            return bounds.contains(r) && !r.intersects(bar) && !r.intersects(hint.insetBy(dx: -6, dy: -6))
        } ?? candidates.last!
        drawPill(text, at: NSPoint(x: min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 4), y: origin.y))
    }

    private func drawActionBar(for selection: NSRect) {
        let bar = barRect(for: selection)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor(calibratedWhite: 0.1, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 10, yRadius: 10).fill()
        NSGraphicsContext.restoreGraphicsState()

        for (i, image) in buttonImages.enumerated() {
            let r = buttonRect(i, in: bar)
            if hoveredButton == i {
                NSColor.white.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            }
            let imageRect = NSRect(x: r.midX - image.size.width / 2, y: r.midY - image.size.height / 2,
                                   width: image.size.width, height: image.size.height)
            image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: hoveredButton == i ? 1 : 0.85)
        }
    }

    private func hintRect(_ text: String) -> NSRect {
        let size = pillSize(for: text)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 48, width: size.width, height: size.height)
    }

    private func drawHint(_ text: String) {
        drawPill(text, at: hintRect(text).origin)
    }

    /// Full-screen crosshair lines through the cursor.
    private func drawGuides(at p: NSPoint) {
        NSColor.white.withAlphaComponent(0.45).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let x = p.x.rounded(.down) + 0.5
        let y = p.y.rounded(.down) + 0.5
        path.move(to: NSPoint(x: x, y: bounds.minY)); path.line(to: NSPoint(x: x, y: bounds.maxY))
        path.move(to: NSPoint(x: bounds.minX, y: y)); path.line(to: NSPoint(x: bounds.maxX, y: y))
        path.stroke()
    }

    /// Magnified pixel grid around the cursor, with coordinates and the pixel's color.
    private func drawLoupe(at p: NSPoint) {
        let loupeSize = CGFloat(loupePixels) * pointsPerPixel
        let radius: CGFloat = 8
        let gap: CGFloat = 24

        let px = Int((p.x * scale).rounded(.down)).clamped(0, cgImage.width - 1)
        let py = Int((bounds.height - p.y) * scale).clamped(0, cgImage.height - 1)
        let pixelColor = color(x: px, y: py)
        let text = "\(px), \(py)    \(hex(pixelColor))"
        let label = pillSize(for: text, swatch: true)
        let labelGap: CGFloat = 6
        let totalHeight = loupeSize + labelGap + label.height

        var origin = NSPoint(x: p.x + gap, y: p.y - gap - totalHeight)
        if origin.x + max(loupeSize, label.width) > bounds.maxX { origin.x = p.x - gap - max(loupeSize, label.width) }
        if origin.y < bounds.minY { origin.y = p.y + gap }
        let loupe = NSRect(x: origin.x, y: origin.y + label.height + labelGap, width: loupeSize, height: loupeSize)
        let clip = NSBezierPath(roundedRect: loupe, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        NSColor.black.setFill()
        clip.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        clip.addClip()

        let half = loupePixels / 2
        let region = CGRect(x: px - half, y: py - half, width: loupePixels, height: loupePixels)
        let visible = region.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        if !visible.isEmpty, let cropped = cgImage.cropping(to: visible), let ctx = NSGraphicsContext.current?.cgContext {
            let dx = (visible.minX - region.minX) * pointsPerPixel
            let dyTop = (visible.minY - region.minY) * pointsPerPixel
            let drawRect = CGRect(x: loupe.minX + dx,
                                  y: loupe.maxY - dyTop - visible.height * pointsPerPixel,
                                  width: visible.width * pointsPerPixel,
                                  height: visible.height * pointsPerPixel)
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.draw(cropped, in: drawRect)
            ctx.restoreGState()
        }

        NSColor.white.withAlphaComponent(0.14).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 1
        for i in 1..<loupePixels {
            let o = CGFloat(i) * pointsPerPixel + 0.5
            grid.move(to: NSPoint(x: loupe.minX + o, y: loupe.minY)); grid.line(to: NSPoint(x: loupe.minX + o, y: loupe.maxY))
            grid.move(to: NSPoint(x: loupe.minX, y: loupe.minY + o)); grid.line(to: NSPoint(x: loupe.maxX, y: loupe.minY + o))
        }
        grid.stroke()

        let center = NSRect(x: loupe.minX + CGFloat(half) * pointsPerPixel,
                            y: loupe.minY + CGFloat(half) * pointsPerPixel,
                            width: pointsPerPixel, height: pointsPerPixel)
        NSColor.black.withAlphaComponent(0.6).setStroke()
        stroke(NSBezierPath(rect: center.insetBy(dx: -0.5, dy: -0.5)))
        NSColor.white.setStroke()
        stroke(NSBezierPath(rect: center.insetBy(dx: 0.5, dy: 0.5)))
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        stroke(NSBezierPath(roundedRect: loupe.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius))

        drawPill(text, at: NSPoint(x: loupe.minX, y: origin.y), swatch: pixelColor)
    }

    // MARK: Helpers

    private func stroke(_ path: NSBezierPath, width: CGFloat = 1) {
        path.lineWidth = width
        path.stroke()
    }

    private func color(x: Int, y: Int) -> NSColor {
        guard let pixel = cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let c = NSBitmapImageRep(cgImage: pixel).colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else { return .black }
        return c
    }

    private func hex(_ c: NSColor) -> String {
        String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    private var pillAttributes: [NSAttributedString.Key: Any] {
        [.font: labelFont, .foregroundColor: NSColor.white]
    }

    private func pillSize(for text: String, swatch: Bool = false) -> NSSize {
        let textSize = (text as NSString).size(withAttributes: pillAttributes)
        return NSSize(width: textSize.width + pillPadding.width * 2 + (swatch ? swatchWidth + 6 : 0),
                      height: textSize.height + pillPadding.height * 2)
    }

    /// Rounded dark label with a soft shadow; optional color swatch on the left.
    private func drawPill(_ text: String, at origin: NSPoint, swatch: NSColor? = nil) {
        let size = pillSize(for: text, swatch: swatch != nil)
        let rect = NSRect(origin: origin, size: size)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor(calibratedWhite: 0.08, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: rect, xRadius: size.height / 2, yRadius: size.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()

        var textX = origin.x + pillPadding.width
        if let swatch {
            let box = NSRect(x: textX, y: origin.y + (size.height - swatchWidth) / 2, width: swatchWidth, height: swatchWidth)
            swatch.setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            NSColor.white.withAlphaComponent(0.6).setStroke()
            stroke(NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3))
            textX += swatchWidth + 6
        }
        (text as NSString).draw(at: NSPoint(x: textX, y: origin.y + pillPadding.height), withAttributes: pillAttributes)
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}
