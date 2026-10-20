import AppKit
import UniformTypeIdentifiers

@MainActor final class AnnotationEditorController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var canvas: AnnotationCanvasView?
    private var sourceImage: CGImage?
    private var restoreApplication: NSRunningApplication?
    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private var undoButton: NSButton?
    private var redoButton: NSButton?
    private var deleteButton: NSButton?
    private var isClosing = false

    var onCopy: ((Data) -> Void)?
    var onPin: ((NSImage) -> Void)?
    var onMessage: ((String) -> Void)?
    var isPresenting: Bool { window != nil }

    private let colors: [(String, NSColor)] = [
        ("红色", .systemRed), ("橙色", .systemOrange), ("黄色", .systemYellow),
        ("绿色", .systemGreen), ("蓝色", .systemBlue), ("黑色", .black), ("白色", .white)
    ]

    func present(_ image: CGImage, restoreApplication: NSRunningApplication?) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            onMessage?("请先完成或取消当前截图标注。")
            return
        }
        guard image.width >= 2, image.height >= 2 else { return }
        self.sourceImage = image
        self.restoreApplication = restoreApplication
        isClosing = false
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let availableW = max(640, visible.width - 48)
        let availableH = max(360, visible.height - 120)
        let imageScale = min(1, availableW / CGFloat(image.width), (availableH - 76) / CGFloat(image.height))
        let contentW = max(860, min(availableW, CGFloat(image.width) * imageScale + 48))
        let contentH = max(300, min(availableH, CGFloat(image.height) * imageScale + 76))
        let contentRect = NSRect(x: 0, y: 0, width: contentW, height: contentH)

        let window = NSWindow(contentRect: contentRect, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Flowmori 截图标注"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 860, height: 320)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating

        let canvas = AnnotationCanvasView(frame: .zero, image: image)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        let toolbar = NSVisualEffectView()
        toolbar.material = .headerView; toolbar.blendingMode = .withinWindow; toolbar.state = .active
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(frame: contentRect)
        root.addSubview(toolbar); root.addSubview(canvas)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 52),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        buildToolbar(in: toolbar, canvas: canvas)
        window.contentView = root
        self.window = window
        self.canvas = canvas
        canvas.onStateChange = { [weak self] in self?.refreshState() }
        canvas.onCancel = { [weak self] in self?.cancel() }
        window.center()
        if let screen { window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                                                       y: screen.visibleFrame.midY - window.frame.height / 2)) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        canvas.tool = .rectangle
        refreshState()
    }

    func focus() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    func close() { closeEditor(restore: false) }
    func cancel() { closeEditor(restore: true) }
    func windowWillClose(_ notification: Notification) {
        if !isClosing { closeEditor(restore: true) }
    }
    private func closeEditor(restore: Bool) {
        guard !isClosing else { return }
        isClosing = true
        window?.delegate = nil
        window?.orderOut(nil)
        window?.close()
        window = nil; canvas = nil; sourceImage = nil
        toolButtons.removeAll(); colorButtons.removeAll()
        undoButton = nil; redoButton = nil; deleteButton = nil
        let app = restoreApplication
        restoreApplication = nil
        if restore, let app, !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.activate(options: [])
        }
        isClosing = false
    }

    private func buildToolbar(in toolbar: NSView, canvas: AnnotationCanvasView) {
        let stack = NSStackView()
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])

        for tool in AnnotationTool.allCases {
            let button = imageButton(symbol: tool.symbol, label: tool.title, action: #selector(pickTool(_:)))
            button.tag = tool.rawValue
            toolButtons.append(button); stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(separator())
        for (index, color) in colors.enumerated() {
            let button = NSButton()
            button.isBordered = false; button.imagePosition = .imageOnly
            button.image = swatch(color.1)
            button.tag = index
            button.target = self; button.action = #selector(pickColor(_:))
            button.toolTip = color.0
            button.setAccessibilityLabel("颜色 \(color.0)")
            button.wantsLayer = true; button.layer?.cornerRadius = 7
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            colorButtons.append(button); stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(separator())
        let widthControl = NSSegmentedControl(labels: ["细", "中", "粗"], trackingMode: .selectOne, target: self, action: #selector(pickWidth(_:)))
        widthControl.selectedSegment = 1
        widthControl.setAccessibilityLabel("线条粗细")
        widthControl.translatesAutoresizingMaskIntoConstraints = false
        widthControl.widthAnchor.constraint(equalToConstant: 104).isActive = true
        stack.addArrangedSubview(widthControl)
        stack.addArrangedSubview(separator())

        undoButton = imageButton(symbol: "arrow.uturn.backward", label: "撤销", action: #selector(undoAction))
        redoButton = imageButton(symbol: "arrow.uturn.forward", label: "重做", action: #selector(redoAction))
        deleteButton = imageButton(symbol: "trash", label: "删除", action: #selector(deleteAction))
        for button in [undoButton, redoButton, deleteButton].compactMap({ $0 }) { stack.addArrangedSubview(button) }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)

        let save = textButton("保存…", label: "保存标注截图", action: #selector(saveAction))
        let pin = textButton("贴图", label: "贴到屏幕", action: #selector(pinAction))
        let cancel = textButton("取消", label: "取消截图标注", action: #selector(cancelAction))
        let done = textButton("复制", label: "完成并复制标注截图", action: #selector(copyAction))
        done.keyEquivalent = "\r"
        for button in [save, pin, cancel, done] { stack.addArrangedSubview(button) }
        pickColor(colorButtons[0])
    }

    private func separator() -> NSBox {
        let box = NSBox(); box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return box
    }
    private func imageButton(symbol: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false; button.bezelStyle = .regularSquare
        button.toolTip = label; button.setAccessibilityLabel(label)
        button.wantsLayer = true; button.layer?.cornerRadius = 6
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }
    private func textButton(_ title: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded; button.controlSize = .small
        button.setAccessibilityLabel(label); button.toolTip = label
        return button
    }
    private func swatch(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        color.setFill(); NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 16, height: 16)).fill()
        NSColor.black.withAlphaComponent(0.22).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 16, height: 16)); ring.lineWidth = 1; ring.stroke()
        image.unlockFocus()
        return image
    }

    @objc private func pickTool(_ sender: NSButton) {
        guard let tool = AnnotationTool(rawValue: sender.tag) else { return }
        canvas?.selectTool(tool)
        refreshState()
    }
    @objc private func pickColor(_ sender: NSButton) {
        guard colors.indices.contains(sender.tag) else { return }
        canvas?.currentColor = colors[sender.tag].1
        for (index, button) in colorButtons.enumerated() {
            button.layer?.borderWidth = index == sender.tag ? 2 : 0
            button.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }
    @objc private func pickWidth(_ sender: NSSegmentedControl) {
        canvas?.currentLineWidth = [2, 4, 8][max(0, min(2, sender.selectedSegment))]
    }
    @objc private func undoAction() { canvas?.endTextEditing(); canvas?.undo() }
    @objc private func redoAction() { canvas?.endTextEditing(); canvas?.redo() }
    @objc private func deleteAction() { canvas?.endTextEditing(); canvas?.deleteSelected() }
    @objc private func cancelAction() { cancel() }

    @objc private func copyAction() {
        canvas?.endTextEditing()
        guard let png = renderPNG() else { fail("无法生成标注图片，请重试。"); return }
        if let onCopy { onCopy(png) }
        else { NSPasteboard.general.clearContents(); NSPasteboard.general.setData(png, forType: .png) }
        onMessage?("截图已复制")
        closeEditor(restore: true)
    }
    @objc private func pinAction() {
        canvas?.endTextEditing()
        guard let png = renderPNG(), let image = NSImage(data: png) else { fail("无法生成标注图片，请重试。"); return }
        onPin?(image)
        closeEditor(restore: true)
    }
    @objc private func saveAction() {
        canvas?.endTextEditing()
        guard let png = renderPNG(), let window else { fail("无法生成标注图片，请重试。"); return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "Flowmori-\(formatter.string(from: Date())).png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url, options: .atomic)
                self?.onMessage?("截图已保存")
                self?.window?.makeKeyAndOrderFront(nil)
            } catch {
                let alert = NSAlert(error: error); alert.beginSheetModal(for: window)
            }
        }
    }
    private func fail(_ message: String) {
        onMessage?(message)
        NSSound.beep()
    }

    private func refreshState() {
        guard let canvas else { return }
        for button in toolButtons { button.state = button.tag == canvas.tool.rawValue ? .on : .off }
        for (index, button) in toolButtons.enumerated() {
            button.layer?.backgroundColor = index == canvas.tool.rawValue
                ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
                : NSColor.clear.cgColor
        }
        undoButton?.isEnabled = canvas.canUndo
        redoButton?.isEnabled = canvas.canRedo
        deleteButton?.isEnabled = canvas.hasSelection
    }

    private func renderPNG() -> Data? {
        guard let image = sourceImage, let canvas else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: CGFloat(width), height: CGFloat(height))
        let export = AnnotationExportView(frame: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
                                          image: image, annotations: canvas.annotations)
        export.layoutSubtreeIfNeeded()
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) { NSGraphicsContext.current = context }
        export.cacheDisplay(in: export.bounds, to: rep)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
