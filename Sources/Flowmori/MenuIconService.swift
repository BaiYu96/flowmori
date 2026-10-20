import AppKit
import ScreenCaptureKit

@MainActor final class MenuIconService: ObservableObject {
    @Published private(set) var icons: [CGWindowID:NSImage] = [:]
    private var operation: Task<Void,Never>?
    private var lastCapture = Date.distantPast
    func refresh(_ entries:[MenuBarEntry]) {
        let ids = Set(entries.map(\.id))
        if icons.keys.contains(where: { !ids.contains($0) }) { icons = icons.filter { ids.contains($0.key) } }
        guard operation == nil, !entries.isEmpty, CGPreflightScreenCaptureAccess(),
              Date().timeIntervalSince(lastCapture) > 15 || entries.contains(where: { icons[$0.id] == nil }) else { return }
        lastCapture = Date()
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.operation = nil }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
                for entry in entries where entry.frame.width > 0 && entry.frame.width < 300 {
                    try Task.checkCancellation()
                    guard let window = content.windows.first(where: { $0.windowID == entry.id }) else { continue }
                    let config = SCStreamConfiguration()
                    config.width = max(1,Int(entry.frame.width * 2)); config.height = max(1,Int(entry.frame.height * 2))
                    config.showsCursor = false; config.captureResolution = .best
                    config.ignoreShadowsSingleWindow = true
                    guard let image = try? await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:window),configuration:config) else { continue }
                    try Task.checkCancellation()
                    self.icons[entry.id] = NSImage(cgImage:image,size:entry.frame.size)
                }
            } catch { /* Application icon remains available if capture is denied or a status window disappears. */ }
        }
    }
    func stop() { operation?.cancel(); operation = nil; icons.removeAll() }
}
