import AppKit
import FlowmoriCore
import UniformTypeIdentifiers

final class SelectionView: NSView {
    let image: CGImage
    var onCopy: ((Data) -> Void)?
    var onPin: ((NSImage) -> Void)?
    var onCancel: (() -> Void)?
    var onMessage: ((String) -> Void)?

    private var startPoint: CGPoint?
    private var selection: CGRect?
    private var moveStartPoint: CGPoint?
    private var moveStartRect: CGRect?
    private var resizeHandle: Int?
    private var canvas: AnnotationCanvasView?
    private var toolbar: CaptureToolbarView?
    private var selectedTool: AnnotationTool = .select
    private var currentColor: NSColor = .systemRed
    private var currentLineWidth: CGFloat = 4
    private var isCompleting = false

    init(frame: NSRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityLabel("截图选择与标注")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var currentSelection: CGRect? { selection }
    var currentCanvas: AnnotationCanvasView? { canvas }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: canvas == nil ? .crosshair : .arrow)
        guard canvas == nil, let selection else { return }
        addCursorRect(selection, cursor: .openHand)
        for (index, rect) in handleRects(for: selection).enumerated() {
            addCursorRect(rect.insetBy(dx: -2, dy: -2), cursor: cursor(forHandle: index))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.draw(image, in: bounds)
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if let selection {
            if canvas == nil {
                context.saveGState()
                context.clip(to: selection)
                context.draw(image, in: bounds)
                context.restoreGState()
                NSColor.controlAccentColor.setStroke()
                let path = NSBezierPath(rect: selection)
                path.lineWidth = 1.5
                path.stroke()
                drawHandles(for: selection)
                drawSizeLabel(for: selection)
            }
        }
        drawHint()
    }

    private func drawSizeLabel(for selection: CGRect) {
        let sx = CGFloat(image.width) / max(1, bounds.width)
        let sy = CGFloat(image.height) / max(1, bounds.height)
        let label = "\(Int(selection.width * sx)) × \(Int(selection.height * sy))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attributes)
        var origin = CGPoint(x: selection.minX + 8, y: selection.maxY + 8)
        if let toolbar, toolbar.frame.minY >= selection.maxY {
            origin.y = max(12, selection.minY - size.height - 8)
        }
        if origin.y + size.height > bounds.maxY - 8 {
            origin.y = max(12, selection.minY - size.height - 8)
        }
        origin.x = min(origin.x, bounds.maxX - size.width - 12)
        let background = CGRect(x: origin.x - 4, y: origin.y - 2,
                                width: size.width + 8, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
        label.draw(at: origin, withAttributes: attributes)
    }

    private func drawHint() {
        let text: String
        if canvas != nil {
            text = "拖动绘制 · Enter 确认复制 · Esc 取消"
        } else if selection != nil {
            text = "拖动选框移动 · 拖角调整 · 选择工具标注 · Enter 复制"
        } else {
            text = "拖动选择区域 · Esc 取消"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: 24, y: bounds.height - size.height - 48)
        let background = CGRect(x: origin.x - 8, y: origin.y - 4,
                                width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.58).setFill()
        NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6).fill()
        text.draw(at: origin, withAttributes: attributes)
    }

    private func handlePoints(for rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }
    private func handleRects(for rect: CGRect) -> [CGRect] {
        handlePoints(for: rect).map { CGRect(x: $0.x - 4, y: $0.y - 4, width: 8, height: 8) }
    }
    private func hitHandle(_ point: CGPoint) -> Int? {
        guard let selection else { return nil }
        return handleRects(for: selection).firstIndex { $0.insetBy(dx: -2, dy: -2).contains(point) }
    }
    private func cursor(forHandle index: Int) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch index {
        case 0: position = .bottomLeft
        case 1: position = .bottom
        case 2: position = .bottomRight
        case 3: position = .right
        case 4: position = .topRight
        case 5: position = .top
        case 6: position = .topLeft
        default: position = .left
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }
    private func drawHandles(for selection: CGRect) {
        for rect in handleRects(for: selection) {
            NSColor.white.setFill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: rect)
            path.fill()
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        if let canvas {
            window?.makeFirstResponder(canvas)
            return
        }
        window?.makeFirstResponder(self)
        if let selection {
            if let handle = hitHandle(point) {
                resizeHandle = handle
                moveStartPoint = point
                moveStartRect = selection
                startPoint = nil
                return
            }
            if selection.insetBy(dx: -1, dy: -1).contains(point) {
                moveStartPoint = point
                moveStartRect = selection
                startPoint = nil
                NSCursor.closedHand.set()
                return
            }
        }
        startPoint = point
        moveStartPoint = nil
        moveStartRect = nil
        resizeHandle = nil
        selection = nil
        hideToolbar()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard canvas == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let handle = resizeHandle, let original = moveStartRect {
            selection = resized(original, handle: handle, to: point)
            layoutToolbar()
            needsDisplay = true
            return
        }
        if let moveStartPoint, let original = moveStartRect {
            var rect = original.offsetBy(dx: point.x - moveStartPoint.x, dy: point.y - moveStartPoint.y)
            rect.origin.x = min(max(0, rect.minX), max(0, bounds.width - rect.width))
            rect.origin.y = min(max(0, rect.minY), max(0, bounds.height - rect.height))
            selection = rect
            layoutToolbar()
            needsDisplay = true
            return
        }
        guard let startPoint else { return }
        selection = CGRect(x: min(startPoint.x, point.x), y: min(startPoint.y, point.y),
                           width: abs(point.x - startPoint.x), height: abs(point.y - startPoint.y))
            .intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard canvas == nil else { return }
        if let selection, selection.width >= 2, selection.height >= 2 {
            self.selection = selection
            showToolbar()
            window?.makeFirstResponder(self)
        } else {
            self.selection = nil
            hideToolbar()
        }
        startPoint = nil
        moveStartPoint = nil
        moveStartRect = nil
        resizeHandle = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.option), event.charactersIgnoringModifiers?.lowercased() == "a" { onCancel?(); return }
        if selection != nil, event.keyCode == 36 { confirm(); return }
        let isCommand = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        if selection != nil, isCommand, event.charactersIgnoringModifiers?.lowercased() == "c" { confirm(); return }
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    func handleKeyDown(_ event: NSEvent) {
        if let canvas { canvas.keyDown(with: event) }
        else { keyDown(with: event) }
    }

    private func resized(_ rect: CGRect, handle: Int, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let point = CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height))
        switch handle {
        case 0: minX = point.x; minY = point.y
        case 1: minY = point.y
        case 2: maxX = point.x; minY = point.y
        case 3: maxX = point.x
        case 4: maxX = point.x; maxY = point.y
        case 5: maxY = point.y
        case 6: minX = point.x; maxY = point.y
        case 7: minX = point.x
        default: break
        }
        if maxX - minX < 2 { if handle == 0 || handle == 6 || handle == 7 { minX = maxX - 2 } else { maxX = minX + 2 } }
        if maxY - minY < 2 { if handle == 0 || handle == 1 || handle == 2 { minY = maxY - 2 } else { maxY = minY + 2 } }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(bounds)
    }

    private func showToolbar() {
        guard selection != nil else { return }
        if toolbar == nil {
            let bar = CaptureToolbarView(width: min(820, max(320, bounds.width - 24)))
            bar.onTool = { [weak self] tool in self?.selectTool(tool) }
            bar.onColor = { [weak self] color in
                guard let self else { return }
                currentColor = color
                canvas?.currentColor = color
                restoreFirstResponder()
            }
            bar.onWidth = { [weak self] width in
                guard let self else { return }
                currentLineWidth = width
                canvas?.currentLineWidth = width
                restoreFirstResponder()
            }
            bar.onUndo = { [weak self] in self?.canvas?.undo(); self?.restoreFirstResponder() }
            bar.onRedo = { [weak self] in self?.canvas?.redo(); self?.restoreFirstResponder() }
            bar.onDelete = { [weak self] in self?.canvas?.deleteSelected(); self?.restoreFirstResponder() }
            bar.onSave = { [weak self] in self?.save() }
            bar.onPin = { [weak self] in self?.pin() }
            bar.onCancel = { [weak self] in self?.onCancel?() }
            bar.onConfirm = { [weak self] in self?.confirm() }
            addSubview(bar)
            toolbar = bar
            bar.setTool(selectedTool)
            bar.refresh(canUndo: false, canRedo: false, canDelete: false)
        }
        layoutToolbar()
    }

    private func hideToolbar() {
        toolbar?.removeFromSuperview()
        toolbar = nil
    }

    private func layoutToolbar() {
        guard let toolbar, let selection else { return }
        let size = toolbar.frame.size
        let gap: CGFloat = 10
        let margin: CGFloat = 12
        var x = selection.midX - size.width / 2
        x = min(max(margin, x), max(margin, bounds.width - size.width - margin))
        var y = selection.minY - size.height - gap
        if y < margin { y = selection.maxY + gap }
        if y + size.height > bounds.height - margin { y = max(margin, bounds.height - size.height - margin) }
        toolbar.frame.origin = NSPoint(x: x, y: y)
    }

    func selectTool(_ tool: AnnotationTool) { apply(tool) }

    private func apply(_ tool: AnnotationTool) {
        guard let selection, selection.width >= 2, selection.height >= 2 else { return }
        if tool == .select {
            if let canvas {
                canvas.endTextEditing()
                if canvas.annotations.isEmpty {
                    removeCanvas()
                } else {
                    canvas.selectTool(.select)
                    window?.makeFirstResponder(canvas)
                }
            } else {
                window?.makeFirstResponder(self)
            }
            selectedTool = .select
            toolbar?.setTool(.select)
            refreshToolbar()
            return
        }
        if canvas == nil {
            guard let cropped = croppedImage(for: selection) else { return }
            let canvas = AnnotationCanvasView(frame: selection, image: cropped)
            canvas.imageFillsBounds = true
            canvas.currentColor = currentColor
            canvas.currentLineWidth = currentLineWidth
            canvas.tool = tool
            canvas.onStateChange = { [weak self] in self?.refreshToolbar() }
            canvas.onCancel = { [weak self] in self?.onCancel?() }
            canvas.onConfirm = { [weak self] in self?.confirm() }
            if let toolbar { addSubview(canvas, positioned: .below, relativeTo: toolbar) }
            else { addSubview(canvas) }
            self.canvas = canvas
        }
        selectedTool = tool
        canvas?.selectTool(tool)
        toolbar?.setTool(tool)
        refreshToolbar()
        window?.makeFirstResponder(canvas)
    }

    private func removeCanvas() {
        canvas?.removeFromSuperview()
        canvas = nil
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        refreshToolbar()
    }

    private func restoreFirstResponder() {
        window?.makeKey()
        window?.makeFirstResponder(canvas ?? self)
    }

    private func refreshToolbar() {
        toolbar?.refresh(canUndo: canvas?.canUndo ?? false,
                         canRedo: canvas?.canRedo ?? false,
                         canDelete: canvas?.hasSelection ?? false)
    }

    private func croppedImage(for selection: CGRect) -> CGImage? {
        let crop = ScreenGeometry.pixelCrop(selection: selection, screen: bounds,
                                            pixelWidth: image.width, pixelHeight: image.height)
        guard crop.width >= 2, crop.height >= 2 else { return nil }
        return image.cropping(to: crop)
    }

    private func renderPNG() -> Data? {
        guard let selection, let cropped = croppedImage(for: selection) else { return nil }
        canvas?.endTextEditing()
        return AnnotationExporter.png(image: cropped, annotations: canvas?.annotations ?? [])
    }

    private func confirm() {
        guard !isCompleting, selection != nil else { return }
        guard let png = renderPNG() else { fail("无法生成截图，请重试。"); return }
        isCompleting = true
        onCopy?(png)
    }

    private func pin() {
        guard !isCompleting, selection != nil else { return }
        guard let png = renderPNG(), let image = NSImage(data: png) else { fail("无法生成截图，请重试。"); return }
        isCompleting = true
        onPin?(image)
    }

    private func save() {
        guard let png = renderPNG(), let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "Flowmori-\(formatter.string(from: Date())).png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url, options: .atomic)
                self?.onMessage?("截图已保存")
            } catch {
                self?.onMessage?("保存失败：\(error.localizedDescription)")
            }
            self?.window?.makeKey()
            self?.restoreFirstResponder()
        }
    }

    private func fail(_ message: String) {
        onMessage?(message)
        NSSound.beep()
    }
}

final class CaptureToolbarView: NSView {
    var onTool: ((AnnotationTool) -> Void)?
    var onColor: ((NSColor) -> Void)?
    var onWidth: ((CGFloat) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSave: (() -> Void)?
    var onPin: (() -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private var undoButton: NSButton?
    private var redoButton: NSButton?
    private var deleteButton: NSButton?
    private let colors: [(String, NSColor)] = [
        ("红色", .systemRed), ("橙色", .systemOrange), ("黄色", .systemYellow),
        ("绿色", .systemGreen), ("蓝色", .systemBlue), ("黑色", .black), ("白色", .white)
    ]

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 44))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        for tool in AnnotationTool.allCases {
            let button = iconButton(tool.symbol, label: tool.title)
            button.tag = tool.rawValue
            button.target = self
            button.action = #selector(pickTool(_:))
            toolButtons.append(button)
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(separator())

        for (index, color) in colors.enumerated() {
            let button = NSButton()
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.image = swatch(color.1)
            button.tag = index
            button.target = self
            button.action = #selector(pickColor(_:))
            button.toolTip = color.0
            button.setAccessibilityLabel("颜色 \(color.0)")
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 24)
            ])
            colorButtons.append(button)
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(separator())

        let widthControl = NSSegmentedControl(labels: ["细", "中", "粗"], trackingMode: .selectOne,
                                              target: self, action: #selector(pickWidth(_:)))
        widthControl.selectedSegment = 1
        widthControl.setAccessibilityLabel("线条粗细")
        widthControl.translatesAutoresizingMaskIntoConstraints = false
        widthControl.widthAnchor.constraint(equalToConstant: 90).isActive = true
        stack.addArrangedSubview(widthControl)
        stack.addArrangedSubview(separator())

        undoButton = iconButton("arrow.uturn.backward", label: "撤销")
        redoButton = iconButton("arrow.uturn.forward", label: "重做")
        deleteButton = iconButton("trash", label: "删除")
        undoButton?.target = self; undoButton?.action = #selector(undoAction)
        redoButton?.target = self; redoButton?.action = #selector(redoAction)
        deleteButton?.target = self; deleteButton?.action = #selector(deleteAction)
        for button in [undoButton, redoButton, deleteButton].compactMap({ $0 }) { stack.addArrangedSubview(button) }
        stack.addArrangedSubview(separator())

        let save = iconButton("square.and.arrow.down", label: "保存截图")
        let pin = iconButton("pin", label: "贴到屏幕")
        save.target = self; save.action = #selector(saveAction)
        pin.target = self; pin.action = #selector(pinAction)
        stack.addArrangedSubview(save)
        stack.addArrangedSubview(pin)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)

        let cancel = textButton("取消", label: "取消截图", action: #selector(cancelAction))
        let confirm = textButton("确认", label: "确认并复制截图", action: #selector(confirmAction))
        stack.addArrangedSubview(cancel)
        stack.addArrangedSubview(confirm)
        setColor(0)
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 1),
            box.heightAnchor.constraint(equalToConstant: 22)
        ])
        return box
    }
    private func iconButton(_ symbol: String, label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
        return button
    }
    private func textButton(_ title: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setAccessibilityLabel(label)
        button.toolTip = label
        return button
    }
    private func swatch(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14)).fill()
        NSColor.black.withAlphaComponent(0.22).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14))
        ring.lineWidth = 1
        ring.stroke()
        image.unlockFocus()
        return image
    }

    func setTool(_ tool: AnnotationTool) {
        for button in toolButtons {
            let selected = button.tag == tool.rawValue
            button.state = selected ? .on : .off
            button.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
                : NSColor.clear.cgColor
        }
    }
    func setColor(_ index: Int) {
        for (buttonIndex, button) in colorButtons.enumerated() {
            button.layer?.borderWidth = buttonIndex == index ? 2 : 0
            button.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }
    func refresh(canUndo: Bool, canRedo: Bool, canDelete: Bool) {
        undoButton?.isEnabled = canUndo
        redoButton?.isEnabled = canRedo
        deleteButton?.isEnabled = canDelete
    }

    @objc private func pickTool(_ sender: NSButton) {
        guard let tool = AnnotationTool(rawValue: sender.tag) else { return }
        onTool?(tool)
        setTool(tool)
    }
    @objc private func pickColor(_ sender: NSButton) {
        guard colors.indices.contains(sender.tag) else { return }
        onColor?(colors[sender.tag].1)
        setColor(sender.tag)
    }
    @objc private func pickWidth(_ sender: NSSegmentedControl) {
        onWidth?([2, 4, 8][max(0, min(2, sender.selectedSegment))])
    }
    @objc private func undoAction() { onUndo?() }
    @objc private func redoAction() { onRedo?() }
    @objc private func deleteAction() { onDelete?() }
    @objc private func saveAction() { onSave?() }
    @objc private func pinAction() { onPin?() }
    @objc private func cancelAction() { onCancel?() }
    @objc private func confirmAction() { onConfirm?() }
}
