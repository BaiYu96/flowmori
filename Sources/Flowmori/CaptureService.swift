import AppKit
import ScreenCaptureKit
import FlowmoriCore

@MainActor final class CaptureService {
    private var panels: [SelectionPanel] = []
    private var snapshots: [CGDirectDisplayID:CGImage] = [:]
    private var capturing = false
    private var previousApplication: NSRunningApplication?
    private var sessionID: UUID?
    private var operation: Task<Void,Never>?
    var onImage: ((Data) -> Void)?
    var onMessage: ((String) -> Void)?
    var beforeCapture: (() -> Void)?
    func begin() {
        guard !capturing else { cancel(); return }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            onMessage?("请允许屏幕录制权限后重试截图。若已授权，请退出并重新打开 Flowmori。")
            return
        }
        previousApplication = NSWorkspace.shared.frontmostApplication
        capturing = true; beforeCapture?()
        let session = UUID()
        sessionID = session
        operation = Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
                try Task.checkCancellation()
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                for display in content.displays {
                    let filter = SCContentFilter(display:display,excludingApplications:ownApps,exceptingWindows:[])
                    let config = SCStreamConfiguration()
                    let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }
                    config.width = Int((screen?.frame.width ?? CGFloat(display.width)) * (screen?.backingScaleFactor ?? 1))
                    config.height = Int((screen?.frame.height ?? CGFloat(display.height)) * (screen?.backingScaleFactor ?? 1))
                    config.captureResolution = .best; config.showsCursor = false
                    let shot = try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
                    try Task.checkCancellation()
                    snapshots[display.displayID] = shot
                }
                guard capturing else { return }
                for screen in NSScreen.screens {
                    guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                          let image = snapshots[id] else { continue }
                    let panel = SelectionPanel(screen:screen,image:image)
                    panel.selectionView.onCancel = { [weak self] in self?.cancel() }
                    panel.selectionView.onSelect = { [weak self,weak screen] rect in
                        guard let self, let screen else { return }
                        self.finish(rect:rect,screen:screen,image:image)
                    }
                    panels.append(panel); panel.orderFrontRegardless()
                }
                guard !panels.isEmpty else { throw CaptureError.noDisplay }
                panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.makeKey()
            } catch is CancellationError { if sessionID == session { cancel() } }
            catch { if sessionID == session { cancel(); onMessage?("截图失败：\(error.localizedDescription)") } }
        }
    }
    private func finish(rect: CGRect, screen: NSScreen, image: CGImage) {
        let global = rect.offsetBy(dx:screen.frame.minX,dy:screen.frame.minY)
        let crop = ScreenGeometry.pixelCrop(selection:global,screen:screen.frame,pixelWidth:image.width,pixelHeight:image.height)
        guard crop.width >= 2, crop.height >= 2, let cropped = image.cropping(to:crop),
              let png = NSBitmapImageRep(cgImage:cropped).representation(using:.png,properties:[:]) else { return }
        cancel(); onImage?(png)
    }
    func cancel() {
        operation?.cancel(); operation = nil
        sessionID = nil
        panels.forEach { $0.orderOut(nil); $0.close() }; panels.removeAll(); snapshots.removeAll(); capturing = false
        if let app = previousApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !app.isTerminated { app.activate(options:[]) }
        previousApplication = nil
    }
    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "无法读取当前显示器" }
    }
}

final class SelectionPanel: NSPanel {
    let selectionView: SelectionView
    init(screen: NSScreen, image: CGImage) {
        selectionView = SelectionView(frame:NSRect(origin:.zero,size:screen.frame.size),image:image)
        super.init(contentRect:screen.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        contentView = selectionView; level = NSWindow.Level(rawValue:Int(CGWindowLevelForKey(.screenSaverWindow)))
        isOpaque = true; backgroundColor = .black; hasShadow = false
        collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        isReleasedWhenClosed = false; acceptsMouseMovedEvents = true
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { selectionView.onCancel?() }
    }
}
final class SelectionView: NSView {
    let image: CGImage
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: CGPoint?
    private var selection: CGRect?
    init(frame: NSRect, image: CGImage) { self.image = image; super.init(frame:frame) }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.crosshair) }
    override func draw(_ dirtyRect:NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.draw(image,in:bounds)
        NSColor.black.withAlphaComponent(0.35).setFill(); bounds.fill()
        if let selection {
            context.saveGState(); context.clip(to:selection); context.draw(image,in:bounds); context.restoreGState()
            NSColor.controlAccentColor.setStroke(); let path = NSBezierPath(rect:selection); path.lineWidth = 1.5; path.stroke()
            let scale = CGFloat(image.width)/bounds.width
            let label = "\(Int(selection.width*scale)) × \(Int(selection.height*scale))"
            label.draw(at:NSPoint(x:selection.minX+8,y:max(12,selection.minY-26)),withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:13,weight:.medium),.foregroundColor:NSColor.white])
        }
        "拖动选择区域 · 松开复制 · Esc 取消".draw(at:NSPoint(x:24,y:24),withAttributes:[.font:NSFont.systemFont(ofSize:15,weight:.medium),.foregroundColor:NSColor.white])
    }
    override func mouseDown(with event:NSEvent) { window?.makeKey(); start = convert(event.locationInWindow,from:nil); selection = nil }
    override func mouseDragged(with event:NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow,from:nil)
        selection = CGRect(x:min(start.x,point.x),y:min(start.y,point.y),width:abs(point.x-start.x),height:abs(point.y-start.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event:NSEvent) {
        mouseDragged(with:event)
        if let selection, selection.width >= 2, selection.height >= 2 { onSelect?(selection) }
        else { start = nil; selection = nil; needsDisplay = true }
    }
    override func keyDown(with event:NSEvent) { if event.keyCode == 53 { onCancel?() } }
}
