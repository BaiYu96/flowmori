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
    var onScreenshot: ((Data) -> Void)?
    var onPin: ((NSImage) -> Void)?
    var onMessage: ((String) -> Void)?
    var beforeCapture: (() -> Void)?
    var isActive: Bool { capturing }
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
                    panel.selectionView.onCopy = { [weak self] png in self?.finish(.copy(png)) }
                    panel.selectionView.onPin = { [weak self] image in self?.finish(.pin(image)) }
                    panel.selectionView.onMessage = { [weak self] message in self?.onMessage?(message) }
                    panels.append(panel); panel.orderFrontRegardless()
                }
                guard !panels.isEmpty else { throw CaptureError.noDisplay }
                NSApp.activate(ignoringOtherApps: true)
                let keyPanel = panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? panels.first
                keyPanel?.makeKeyAndOrderFront(nil)
                if let keyPanel { keyPanel.makeFirstResponder(keyPanel.selectionView) }
            } catch is CancellationError { if sessionID == session { cancel() } }
            catch { if sessionID == session { cancel(); onMessage?("截图失败：\(error.localizedDescription)") } }
        }
    }
    private enum Output {
        case copy(Data)
        case pin(NSImage)
    }
    private func finish(_ output: Output) {
        endSession(restoreFocus:true)
        switch output {
        case .copy(let png): onScreenshot?(png)
        case .pin(let image): onPin?(image)
        }
    }
    func cancel() { _ = endSession(restoreFocus:true) }
    @discardableResult private func endSession(restoreFocus: Bool) -> NSRunningApplication? {
        operation?.cancel(); operation = nil
        sessionID = nil
        panels.forEach { $0.orderOut(nil); $0.close() }; panels.removeAll(); snapshots.removeAll(); capturing = false
        let app = previousApplication
        if restoreFocus, let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !app.isTerminated { app.activate(options:[]) }
        previousApplication = nil
        return app
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
        super.init(contentRect:screen.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        contentView = selectionView; level = NSWindow.Level(rawValue:Int(CGWindowLevelForKey(.screenSaverWindow)))
        isOpaque = true; backgroundColor = .black; hasShadow = false
        collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        isReleasedWhenClosed = false; acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
