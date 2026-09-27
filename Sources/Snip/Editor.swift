import AppKit

enum Tool: Int, CaseIterable {
    case rect = 0, ellipse, line, arrow, pen

    var label: String {
        switch self {
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .pen: return "Pen"
        }
    }

    var symbol: String {
        switch self {
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .pen: return "scribble"
        }
    }
}

struct Shape {
    var tool: Tool
    var color: NSColor
    /// Stored in image points, so export doesn't depend on the on-screen zoom.
    var points: [NSPoint]
}

private extension NSToolbarItem.Identifier {
    static let tools = Self("snip.tools")
    static let color = Self("snip.color")
    static let undo = Self("snip.undo")
    static let folder = Self("snip.folder")
    static let save = Self("snip.save")
    static let copy = Self("snip.copy")
}

/// Window showing the captured image with an icon toolbar for annotation.
final class EditorWindow: NSWindow, NSWindowDelegate, NSToolbarDelegate {
    var onClose: ((EditorWindow) -> Void)?
    private let editor: EditorView
    private let minToolbarWidth: CGFloat = 480

    init(image: NSImage) {
        // Fit the image into ~85% of the screen; never upscale.
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let scale = min(1,
                        screenFrame.width * 0.85 / image.size.width,
                        (screenFrame.height * 0.85 - 52) / image.size.height)
        let viewSize = NSSize(width: (image.size.width * scale).rounded(),
                              height: (image.size.height * scale).rounded())
        editor = EditorView(image: image, frame: NSRect(origin: .zero, size: viewSize))

        let content = NSRect(x: 0, y: 0, width: max(viewSize.width, minToolbarWidth), height: viewSize.height)
        super.init(contentRect: content, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Snip"
        titleVisibility = .hidden
        toolbarStyle = .unifiedCompact
        isReleasedWhenClosed = false
        delegate = self

        let toolbar = NSToolbar(identifier: "snip.editor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        self.toolbar = toolbar

        let root = NSView(frame: content)
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        editor.frame.origin = NSPoint(x: ((content.width - viewSize.width) / 2).rounded(),
                                      y: ((content.height - viewSize.height) / 2).rounded())
        editor.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]  // stay centered
        root.addSubview(editor)
        contentView = root
        setContentSize(content.size)   // the toolbar changes the frame; pin the content area back to the image
        center()
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.tools, .color, .undo, .flexibleSpace, .folder, .save, .copy]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .tools:
            let images = Tool.allCases.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.label)! }
            let control = NSSegmentedControl(images: images, trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
            control.segmentStyle = .automatic
            for (i, tool) in Tool.allCases.enumerated() {
                control.setToolTip(tool.label, forSegment: i)
                control.setWidth(34, forSegment: i)
            }
            control.selectedSegment = 0
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = control
            item.label = "Tool"
            return item

        case .color:
            let well = NSColorWell(style: .minimal)
            well.color = editor.strokeColor
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.toolTip = "Stroke color"
            well.widthAnchor.constraint(equalToConstant: 38).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = well
            item.label = "Color"
            return item

        case .undo:
            return button(id, "arrow.uturn.backward", "Undo (⌘Z)", #selector(undo))
        case .folder:
            return button(id, "folder", "Open folder", #selector(openFolder))
        case .save:
            return button(id, "square.and.arrow.down", "Save to folder & copy (⌘S)", #selector(saveAndClose))
        case .copy:
            return button(id, "doc.on.doc", "Copy to clipboard (⏎)", #selector(copyAndClose))
        default:
            return nil
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, _ symbol: String, _ tip: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        item.label = tip
        item.toolTip = tip
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    // MARK: Actions

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        editor.tool = Tool(rawValue: sender.selectedSegment) ?? .rect
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        editor.strokeColor = sender.color
    }

    @objc private func undo() {
        editor.undoShape()
    }

    @objc private func openFolder() {
        AppDelegate.shared.openFolder()
    }

    @objc func copyAndClose() {
        Export.copy(editor.render())
        close()
    }

    @objc func saveAndClose() {
        Export.save(editor.render())
        close()
    }

    func windowWillClose(_ notification: Notification) {
        NSColorPanel.shared.close()
        onClose?(self)
    }
}

final class EditorView: NSView {
    var tool: Tool = .rect
    var strokeColor = NSColor(calibratedRed: 1, green: 0.23, blue: 0.19, alpha: 1)

    private let image: NSImage
    private var shapes: [Shape] = []
    private var history: [[Shape]] = []     // snapshots for undo (new shape or move)
    private var current: Shape?             // shape being drawn
    private var dragging: (index: Int, last: NSPoint)?   // shape being moved
    private let lineWidth: CGFloat = 3
    private let hitSlop: CGFloat = 8        // extra grab width around a shape's outline, in image points

    /// View units per image point.
    private var zoom: CGFloat { bounds.width / image.size.width }

    init(image: NSImage, frame: NSRect) {
        self.image = image
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: frame, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    private func imagePoint(_ event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil)
        return NSPoint(x: p.x / zoom, y: p.y / zoom)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: window?.close()                                   // Esc
        case 36, 76: (window as? EditorWindow)?.copyAndClose()     // Return / Enter
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "s": (window as? EditorWindow)?.saveAndClose(); return true
        case "z": undoShape(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: Hit testing

    /// Index of the topmost shape whose outline is under `p`, if any.
    private func shapeIndex(at p: NSPoint) -> Int? {
        for (i, shape) in shapes.enumerated().reversed() {
            let outline = outlinePath(for: shape).cgPath
                .copy(strokingWithWidth: lineWidth + hitSlop * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
            if outline.contains(p) { return i }
        }
        return nil
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        let p = imagePoint(event)
        (shapeIndex(at: p) == nil ? NSCursor.crosshair : NSCursor.openHand).set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = imagePoint(event)
        if let index = shapeIndex(at: p) {
            history.append(shapes)
            dragging = (index, p)
            NSCursor.closedHand.set()
            return
        }
        current = Shape(tool: tool, color: strokeColor, points: [p, p])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        if let drag = dragging {
            let dx = p.x - drag.last.x, dy = p.y - drag.last.y
            shapes[drag.index].points = shapes[drag.index].points.map { NSPoint(x: $0.x + dx, y: $0.y + dy) }
            dragging = (drag.index, p)
            needsDisplay = true
            return
        }
        guard current != nil else { return }
        if tool == .pen {
            current?.points.append(p)
        } else {
            current?.points[1] = p
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if dragging != nil {
            dragging = nil
            NSCursor.openHand.set()
            return
        }
        if let current {
            history.append(shapes)
            shapes.append(current)
        }
        current = nil
        needsDisplay = true
    }

    @objc func undoShape() {
        guard let previous = history.popLast() else { return }
        shapes = previous
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: zoom, y: zoom)
        drawShapes()
        ctx.restoreGState()
    }

    private func drawShapes() {
        for shape in shapes { draw(shape) }
        if let current { draw(current) }
    }

    /// The stroked outline of a shape (arrow head excluded).
    private func outlinePath(for shape: Shape) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let a = shape.points[0], b = shape.points[1]
        let box = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))

        switch shape.tool {
        case .rect:
            path.appendRoundedRect(box, xRadius: 2, yRadius: 2)
        case .ellipse:
            path.appendOval(in: box)
        case .line, .arrow:
            path.move(to: a)
            path.line(to: b)
        case .pen:
            path.move(to: shape.points[0])
            for p in shape.points.dropFirst() { path.line(to: p) }
        }
        return path
    }

    private func arrowHead(for shape: Shape) -> NSBezierPath {
        let a = shape.points[0], b = shape.points[1]
        let angle = atan2(b.y - a.y, b.x - a.x)
        let length: CGFloat = 14
        let spread: CGFloat = .pi / 7
        let head = NSBezierPath()
        head.move(to: b)
        head.line(to: NSPoint(x: b.x - length * cos(angle - spread), y: b.y - length * sin(angle - spread)))
        head.line(to: NSPoint(x: b.x - length * cos(angle + spread), y: b.y - length * sin(angle + spread)))
        head.close()
        return head
    }

    private func draw(_ shape: Shape) {
        shape.color.setStroke()
        shape.color.setFill()
        outlinePath(for: shape).stroke()
        if shape.tool == .arrow { arrowHead(for: shape).fill() }
    }

    /// Flattens image + annotations at the capture's full pixel resolution.
    func render() -> NSImage {
        let pixelsWide = image.representations.first?.pixelsWide ?? Int(image.size.width)
        let pixelsHigh = image.representations.first?.pixelsHigh ?? Int(image.size.height)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Work in image points; scale up to the bitmap's pixel grid.
        context.cgContext.scaleBy(x: CGFloat(pixelsWide) / image.size.width,
                                  y: CGFloat(pixelsHigh) / image.size.height)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        drawShapes()
        NSGraphicsContext.restoreGraphicsState()

        rep.size = image.size
        let out = NSImage(size: image.size)
        out.addRepresentation(rep)
        return out
    }
}
