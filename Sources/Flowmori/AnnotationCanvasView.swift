import AppKit

final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    let image: CGImage
    var annotations: [Annotation] = []
    var tool: AnnotationTool = .rectangle {
        didSet {
            if tool != .select { selectedID = nil }
            window?.invalidateCursorRects(for: self)
            onStateChange?()
        }
    }
    var currentColor: NSColor = .systemRed
    var currentLineWidth: CGFloat = 4
    var onStateChange: (() -> Void)?
    var onCancel: (() -> Void)?
    private(set) var undoStack: [[Annotation]] = []
    private(set) var redoStack: [[Annotation]] = []
    private var selectedID: UUID?
    private var draft: Annotation?
    private var dragStart: CGPoint?
    private var lastPoint: CGPoint?
    private var mutationSnapshot: [Annotation]?
    private var resizeHandle: Int?
    private var didMutate = false
    private var textScroll: NSScrollView?
    private var textView: AnnotationTextView?
    private var textDraft: Annotation?
    private var textSnapshot: [Annotation]?
    private var editingTextID: UUID?
    private var isCommittingText = false

    init(frame: NSRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1).cgColor
        setAccessibilityLabel("截图标注画布")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() {
        let cursor: NSCursor = tool == .select ? .arrow : (tool == .text ? .iBeam : .crosshair)
        addCursorRect(bounds, cursor: cursor)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasSelection: Bool { selectedID != nil }
    var isEditingText: Bool { textView != nil }

    var imageRect: CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let available = bounds.insetBy(dx: 24, dy: 24)
        let scale = min(1, available.width / CGFloat(image.width), available.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    var displayScale: CGFloat {
        guard image.width > 0 else { return 1 }
        return imageRect.width / CGFloat(image.width)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill(); bounds.fill()
        let target = imageRect
        NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width), height: CGFloat(image.height)))
            .draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                  hints: [.interpolation: NSImageInterpolation.high])
        NSColor.white.withAlphaComponent(0.16).setStroke()
        let border = NSBezierPath(rect: target); border.lineWidth = 1; border.stroke()
        for annotation in annotations {
            AnnotationRenderer.draw(annotation, imageRect: target, scale: displayScale)
        }
        if let draft { AnnotationRenderer.draw(draft, imageRect: target, scale: displayScale) }
        if let selected = selectedAnnotation {
            drawSelection(selected)
        }
    }

    private var selectedAnnotation: Annotation? {
        guard let selectedID else { return nil }
        return annotations.first { $0.id == selectedID }
    }
    private func drawSelection(_ annotation: Annotation) {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: viewRect(annotation.bounds).insetBy(dx: -2, dy: -2))
        path.lineWidth = 1; path.setLineDash([4, 3], count: 2, phase: 0); path.stroke()
        for (_, rect) in handleRects(for: annotation) {
            NSColor.white.setFill(); NSColor.controlAccentColor.setStroke()
            let handle = NSBezierPath(rect: rect); handle.fill(); handle.lineWidth = 1; handle.stroke()
        }
    }

    private func viewPoint(_ point: CGPoint) -> CGPoint {
        AnnotationRenderer.viewPoint(point, imageRect: imageRect, scale: displayScale)
    }
    private func viewRect(_ rect: CGRect) -> CGRect {
        AnnotationRenderer.viewRect(rect, imageRect: imageRect, scale: displayScale)
    }
    private func imagePoint(_ point: CGPoint) -> CGPoint {
        guard displayScale > 0 else { return .zero }
        return CGPoint(x: (point.x - imageRect.minX) / displayScale, y: (point.y - imageRect.minY) / displayScale)
    }
    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), CGFloat(image.width)), y: min(max(0, point.y), CGFloat(image.height)))
    }
    private func handleRects(for annotation: Annotation) -> [(Int, CGRect)] {
        annotation.handles.enumerated().map { index, point in
            let p = viewPoint(point)
            return (index, CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
        }
    }

    private func pushUndo(_ snapshot: [Annotation]) {
        undoStack.append(snapshot)
        redoStack.removeAll()
        onStateChange?()
    }
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        selectedID = nil
        needsDisplay = true
        onStateChange?()
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        selectedID = nil
        needsDisplay = true
        onStateChange?()
    }
    func deleteSelected() {
        guard let selectedID, let index = annotations.firstIndex(where: { $0.id == selectedID }) else { return }
        pushUndo(annotations)
        annotations.remove(at: index)
        self.selectedID = nil
        needsDisplay = true
        onStateChange?()
    }

    override func mouseDown(with event: NSEvent) {
        if isEditingText {
            endTextEditing()
            return
        }
        window?.makeFirstResponder(self)
        let point = clamp(imagePoint(convert(event.locationInWindow, from: nil)))
        switch tool {
        case .select:
            if let selected = selectedAnnotation {
                for (index, rect) in handleRects(for: selected) where rect.insetBy(dx: -3, dy: -3).contains(convert(event.locationInWindow, from: nil)) {
                    mutationSnapshot = annotations
                    resizeHandle = index
                    dragStart = point
                    didMutate = false
                    return
                }
            }
            let tolerance = max(6, 10 / max(displayScale, 0.01))
            let hit = annotations.reversed().first { $0.hitTest(point, tolerance: tolerance) }
            selectedID = hit?.id
            if let hit, event.clickCount == 2, hit.kind == .text {
                beginEditingText(hit)
                return
            }
            if hit != nil {
                mutationSnapshot = annotations
                dragStart = point
                lastPoint = point
                didMutate = false
            }
            needsDisplay = true
            onStateChange?()
        case .rectangle, .arrow, .pen:
            draft = tool == .rectangle
                ? .rectangle(from: point, to: point, color: currentColor, lineWidth: currentLineWidth)
                : (tool == .arrow ? .arrow(from: point, to: point, color: currentColor, lineWidth: currentLineWidth)
                                  : .pen(points: [point], color: currentColor, lineWidth: currentLineWidth))
            dragStart = point
            needsDisplay = true
        case .text:
            beginNewText(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamp(imagePoint(convert(event.locationInWindow, from: nil)))
        switch tool {
        case .select:
            guard let selectedID, let index = annotations.firstIndex(where: { $0.id == selectedID }) else { return }
            if let resizeHandle {
                annotations[index].resize(handle: resizeHandle, to: point, inside: CGSize(width: CGFloat(image.width), height: CGFloat(image.height)))
                didMutate = true
            } else if let lastPoint {
                annotations[index].move(by: CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y),
                                        inside: CGSize(width: CGFloat(image.width), height: CGFloat(image.height)))
                self.lastPoint = point
                didMutate = true
            }
            needsDisplay = true
        case .rectangle:
            guard let dragStart else { return }
            draft = .rectangle(from: dragStart, to: point, color: currentColor, lineWidth: currentLineWidth)
            needsDisplay = true
        case .arrow:
            guard let dragStart else { return }
            draft = .arrow(from: dragStart, to: point, color: currentColor, lineWidth: currentLineWidth)
            needsDisplay = true
        case .pen:
            draft?.points.append(point)
            needsDisplay = true
        case .text:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch tool {
        case .select:
            if didMutate, let mutationSnapshot {
                pushUndo(mutationSnapshot)
            }
            mutationSnapshot = nil
            resizeHandle = nil
            dragStart = nil
            lastPoint = nil
            didMutate = false
            needsDisplay = true
        case .rectangle, .arrow:
            guard var draft, dragStart != nil else { return }
            if abs(draft.end.x - draft.start.x) >= 2 || abs(draft.end.y - draft.start.y) >= 2 || draft.kind == .rectangle {
                if draft.kind == .rectangle, (draft.rect.width < 2 || draft.rect.height < 2) {
                    self.draft = nil; needsDisplay = true; return
                }
                draft.id = UUID()
                pushUndo(annotations)
                annotations.append(draft)
                selectedID = draft.id
            }
            self.draft = nil; dragStart = nil; needsDisplay = true; onStateChange?()
        case .pen:
            guard var draft, draft.points.count > 1 else { self.draft = nil; dragStart = nil; needsDisplay = true; return }
            draft.id = UUID()
            pushUndo(annotations)
            annotations.append(draft)
            selectedID = draft.id
            self.draft = nil; dragStart = nil; needsDisplay = true; onStateChange?()
        case .text:
            break
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if isEditingText { endTextEditing() }
            else if draft != nil { draft = nil; dragStart = nil; needsDisplay = true }
            else { onCancel?() }
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            if !isEditingText { deleteSelected() }
            return
        }
        let isCommand = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        if isCommand, event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) { redo() } else { undo() }
            return
        }
        if event.keyCode == 36, hasSelection { return }
        super.keyDown(with: event)
    }
    override func cancelOperation(_ sender: Any?) {
        if isEditingText { endTextEditing() }
        else if draft != nil { draft = nil; needsDisplay = true }
        else { onCancel?() }
    }

    func selectTool(_ tool: AnnotationTool) {
        endTextEditing()
        self.tool = tool
        window?.makeFirstResponder(self)
    }
    func endTextEditing() {
        guard !isCommittingText, let textView else { return }
        isCommittingText = true
        let value = textView.string
        let width = textDraft?.textWidth ?? 260
        removeTextEditor()
        guard let draft = textDraft else { isCommittingText = false; return }
        let snapshot = textSnapshot ?? annotations
        var updated = draft
        updated.text = value
        updated.textWidth = width
        if let editingTextID, let index = annotations.firstIndex(where: { $0.id == editingTextID }) {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pushUndo(snapshot); annotations.remove(at: index); selectedID = nil
            } else {
                pushUndo(snapshot); annotations[index] = updated; selectedID = updated.id
            }
        } else if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pushUndo(snapshot); annotations.append(updated); selectedID = updated.id
        }
        textDraft = nil; textSnapshot = nil; editingTextID = nil
        isCommittingText = false
        needsDisplay = true
        window?.makeFirstResponder(self)
        onStateChange?()
    }
    func textDidEndEditing(_ notification: Notification) {
        if !isCommittingText { endTextEditing() }
    }

    private func beginNewText(at point: CGPoint) {
        let width = min(360, max(120, CGFloat(image.width) - point.x - 20))
        textDraft = .text("", at: point, width: width, fontSize: 22, color: currentColor)
        textSnapshot = annotations
        editingTextID = nil
        showTextEditor()
    }
    private func beginEditingText(_ annotation: Annotation) {
        textDraft = annotation
        textSnapshot = annotations
        editingTextID = annotation.id
        showTextEditor()
    }
    private func showTextEditor() {
        guard let draft = textDraft else { return }
        removeTextEditor()
        let scale = displayScale
        let origin = viewPoint(CGPoint(x: draft.rect.minX, y: draft.rect.minY))
        let width = max(120, min(draft.textWidth * scale, bounds.maxX - origin.x - 8))
        let desired = max(74, draft.textHeight * scale + 16)
        let height = max(60, min(desired, bounds.maxY - origin.y - 8))
        let scroll = NSScrollView(frame: CGRect(x: origin.x, y: origin.y, width: width, height: height))
        scroll.borderType = .noBorder; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let text = AnnotationTextView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        text.delegate = self
        text.isRichText = false; text.importsGraphics = false
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.drawsBackground = true
        text.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.94)
        text.textColor = NSColor.labelColor
        text.insertionPointColor = draft.color
        text.font = NSFont.systemFont(ofSize: max(12, draft.fontSize * scale))
        text.textContainerInset = NSSize(width: 5, height: 5)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        text.string = draft.text
        text.onEscape = { [weak self] in self?.endTextEditing() }
        text.setSelectedRange(NSRange(location: (draft.text as NSString).length, length: 0))
        scroll.documentView = text
        addSubview(scroll)
        textScroll = scroll; textView = text
        window?.makeFirstResponder(text)
    }
    private func removeTextEditor() {
        textScroll?.removeFromSuperview()
        textScroll = nil; textView = nil
    }
}

final class AnnotationTextView: NSTextView {
    var onEscape: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !hasMarkedText() {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}
