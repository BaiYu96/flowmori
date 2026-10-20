import AppKit
import SwiftUI
import FlowmoriCore
import OSLog

@MainActor final class AppController: NSObject, ObservableObject {
    let settings = Settings()
    let hotkeys = HotkeyManager()
    let pins = PinController()
    let capture = CaptureService()
    let dataDirectory: URL
    let statusItem: NSStatusItem
    var clipboard: ClipboardService?
    var menuManager: MenuBarManager!
    private var historyPanel: HistoryPanelController?
    private var collectionPanel: CollectionPanelController!
    private var settingsWindow: NSWindow?
    private var toastPanel: NSPanel?
    private var toastTask: Task<Void,Never>?
    private var refreshTimer: Timer?
    private var diagnosticTimer: Timer?
    private var diagnosticsURL: URL?
    private var systemObservers: [NSObjectProtocol] = []
    private let launchTime = Date()
    private let logger = Logger(subsystem:"app.flowmori.Flowmori",category:"Lifecycle")
    @Published var startupError: String?
    @Published var hotkeyErrors: [AppAction:String] = [:]
    init(diagnosticsURL:URL? = nil, migrationError:Error? = nil) {
        self.diagnosticsURL = diagnosticsURL
        dataDirectory = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Flowmori",isDirectory:true)
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        super.init()
        statusItem.autosaveName = "Flowmori.Main"
        statusItem.button?.image = NSImage(systemSymbolName:"square.stack.3d.up",accessibilityDescription:"Flowmori")
        statusItem.button?.toolTip = "Flowmori · 左键收纳 · 右键工具菜单"
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on:[.leftMouseUp,.rightMouseUp])
        do {
            if let migrationError { throw migrationError }
            let repository = try HistoryRepository(directory:dataDirectory)
            let service = ClipboardService(settings:settings,repository:repository,directory:dataDirectory)
            service.onMessage = { [weak self] message in self?.toast(message) }
            clipboard = service
            historyPanel = HistoryPanelController(service:service,settings:settings)
            historyPanel?.onPin = { [weak self] image in self?.pins.pin(image) }
            historyPanel?.onSettings = { [weak self] in self?.showSettings() }
            service.start()
        } catch { startupError = "历史存储初始化失败：\(error.localizedDescription)。其他功能仍可使用。" }
        menuManager = MenuBarManager(settings:settings,control:statusItem,dataDirectory:dataDirectory)
        menuManager.onMessage = { [weak self] message in self?.toast(message) }
        collectionPanel = CollectionPanelController(manager:menuManager,settings:settings,statusItem:statusItem)
        collectionPanel.onSettings = { [weak self] in self?.showSettings() }
        capture.beforeCapture = { [weak self] in self?.historyPanel?.close(restore:false); self?.collectionPanel.close() }
        capture.onImage = { [weak self] data in
            guard let self else { return }
            if let clipboard = self.clipboard { clipboard.acceptScreenshot(data) }
            else { NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data,forType:.png); self.toast("截图已复制") }
        }
        capture.onMessage = { [weak self] message in self?.toast(message) }
        pins.onCopy = { [weak self] data in
            if let clipboard = self?.clipboard { _ = clipboard.write(ClipPayload(kind:.image,imagePNG:data)); clipboard.enqueue(ClipPayload(kind:.image,imagePNG:data)) }
            else { NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data,forType:.png) }
        }
        pins.onMessage = { [weak self] message in self?.toast(message) }
        hotkeys.onAction = { [weak self] action in
            guard let self else { return }
            // Carbon delivers a registered chord before AppKit keyDown. Feed it
            // to an active recorder so conflicts are reported without invoking it.
            if let shortcut = self.settings.shortcuts[action], RecorderButton.captureRegisteredShortcut(shortcut) { return }
            self.perform(action)
        }
        for action in AppAction.allCases {
            do { try hotkeys.register(action,shortcut:settings.shortcuts[action]!,current:settings.shortcuts) }
            catch { hotkeyErrors[action] = error.localizedDescription }
        }
        let firstLaunch = settings.configureFirstLaunch()
        if firstLaunch || startupError != nil { showSettings() }
        refreshTimer = Timer(timeInterval:3,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.settings.refreshPermissions(); self?.pins.constrainToScreens() }
        }
        RunLoop.main.add(refreshTimer!,forMode:.common)
        if diagnosticsURL != nil {
            diagnosticTimer = Timer(timeInterval:15,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.writeDiagnostics() } }
            RunLoop.main.add(diagnosticTimer!,forMode:.common); writeDiagnostics()
        }
        systemObservers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.capture.cancel(); self?.pins.constrainToScreens() } })
        systemObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.capture.cancel() } })
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(showSettings),name:NSNotification.Name("app.flowmori.showSettings"),object:nil)
        logger.info("Flowmori started")
    }
    func perform(_ action:AppAction) {
        switch action {
        case .history:
            collectionPanel.close()
            if let historyPanel { historyPanel.toggle() } else { toast(startupError ?? "历史暂不可用") }
        case .capture: capture.begin()
        case .pin:
            if let image = clipboard?.currentImage() { pins.pin(image) }
            else if clipboard == nil, let image = NSImage(pasteboard:.general) { pins.pin(image) }
            else { toast("剪贴板里没有图片。先截图或复制一张图片，再按快捷键贴出。") }
        case .collection: historyPanel?.close(restore:false); collectionPanel.toggle()
        }
    }
    func changeShortcut(_ action:AppAction,to shortcut:Shortcut) {
        if let current = settings.shortcuts[action], current.matches(shortcut), hotkeyErrors[action] == nil { return }
        do {
            try hotkeys.register(action,shortcut:shortcut,current:settings.shortcuts)
            settings.saveShortcut(shortcut,for:action); hotkeyErrors.removeValue(forKey:action)
        } catch { hotkeyErrors[action] = error.localizedDescription }
    }
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            collectionPanel.close(); showMenu()
        } else { perform(.collection) }
    }
    private func showMenu() {
        let menu = NSMenu()
        for action in AppAction.allCases {
            let key = settings.shortcuts[action]?.display ?? ""
            let item = NSMenuItem(title:"\(action.title)    \(key)",action:#selector(menuAction(_:)),keyEquivalent:"")
            item.representedObject = action.rawValue; item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        addMenu(menu,title:settings.paused ? "继续记录剪贴板" : "暂停记录剪贴板",selector:#selector(togglePaused))
        addMenu(menu,title:"显示／隐藏全部贴图",selector:#selector(togglePins))
        addMenu(menu,title:"关闭全部贴图",selector:#selector(closePins))
        addMenu(menu,title:"暂停收纳／全部展开",selector:#selector(pauseCollection))
        menu.addItem(.separator())
        addMenu(menu,title:"设置…",selector:#selector(showSettings))
        addMenu(menu,title:"退出 Flowmori",selector:#selector(quit))
        if let button = statusItem.button { menu.popUp(positioning:nil,at:NSPoint(x:0,y:button.bounds.minY),in:button) }
    }
    private func addMenu(_ menu:NSMenu,title:String,selector:Selector) { let item = NSMenuItem(title:title,action:selector,keyEquivalent:""); item.target = self; menu.addItem(item) }
    @objc private func menuAction(_ sender:NSMenuItem) { if let value = sender.representedObject as? String, let action = AppAction(rawValue:value) { perform(action) } }
    @objc private func togglePaused() { settings.paused.toggle() }
    @objc private func togglePins() { pins.toggleAll() }
    @objc private func closePins() { pins.closeAll() }
    @objc private func pauseCollection() { menuManager.enable(false) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc func showSettings() {
        collectionPanel?.close(); historyPanel?.close(restore:false)
        if settingsWindow == nil {
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:570),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            window.title = "Flowmori 设置"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView:SettingsView(app:self,settings:settings,menu:menuManager))
            window.center(); settingsWindow = window
        }
        settings.refreshPermissions(); NSApp.activate(ignoringOtherApps:true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func toast(_ message:String) {
        toastTask?.cancel(); toastPanel?.close()
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:380,height:78),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.level = .statusBar; panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true; panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView:HStack(spacing:12) { Image(systemName:"square.stack.3d.up").foregroundStyle(.tint); Text(message).font(.system(size:13)).lineLimit(3).frame(maxWidth:.infinity,alignment:.leading) }.padding(16).frame(width:380,height:78).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)))
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main { panel.setFrameOrigin(NSPoint(x:screen.visibleFrame.midX-190,y:screen.visibleFrame.minY+40)) }
        panel.orderFrontRegardless(); toastPanel = panel
        toastTask = Task { try? await Task.sleep(for:.seconds(4)); guard !Task.isCancelled else { return }; panel.close() }
    }
    private func writeDiagnostics() {
        guard let diagnosticsURL else { return }
        let value: [String:Any] = ["timestamp":Date().timeIntervalSince1970,"uptime":Date().timeIntervalSince(launchTime),
                                  "pid":ProcessInfo.processInfo.processIdentifier,"clipboardPolls":clipboard?.pollCount ?? 0,
                                  "records":clipboard?.records.count ?? 0,"pins":pins.count,"menuItems":menuManager.items.count,
                                  "accessibility":settings.accessibilityGranted,"screenCapture":settings.captureGranted,
                                  "menuOperating":menuManager.operating,"menuExpanded":menuManager.expanded,
                                  "loginStatus":settings.loginStatus.rawValue,"hotkeyErrors":hotkeyErrors.mapValues { _ in true }.map { $0.key.rawValue },
                                  "menuEnabled":settings.menuEnabled,
                                  "menuBridgeAvailable":menuManager.supported,
                                  "menuLayout":menuManager.diagnosticSnapshot(),
                                  "detectedStatusWindows":(try? menuManager.system.entries().count) ?? -1,
                                  "screens":NSScreen.screens.count]
        do { try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:diagnosticsURL,options:.atomic) }
        catch { logger.error("Could not write diagnostic heartbeat") }
    }
    func stop() {
        capture.cancel(); clipboard?.stop(); menuManager.stop(); pins.closeAll(); hotkeys.unregisterAll()
        collectionPanel.close(); historyPanel?.close(restore:false)
        refreshTimer?.invalidate(); diagnosticTimer?.invalidate(); toastTask?.cancel()
        for observer in systemObservers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        logger.info("Flowmori stopped")
    }
}
