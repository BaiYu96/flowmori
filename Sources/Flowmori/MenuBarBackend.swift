import AppKit
import ApplicationServices
import FlowmoriCore
import Darwin

struct MenuBarEntry: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let ownerPID: pid_t
    let bundleID: String
    let name: String
    let title: String
    let frame: CGRect // Quartz global coordinates (top-left origin)
    let supportedActions: [String]
    var icon: NSImage? { NSRunningApplication(processIdentifier:ownerPID)?.icon }
    var leftDirectAvailable: Bool { supportedActions.contains(kAXPressAction as String) }
    var rightDirectAvailable: Bool { supportedActions.contains("AXShowMenu") }
    var ownershipResolved: Bool { ownerPID > 0 }
    var protected: Bool {
        ["com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.notificationcenterui", "com.apple.Spotlight"].contains(bundleID)
    }
}

enum MenuBarError: LocalizedError {
    case unavailable, permission, disappeared, busy, moveFailed, unsafePosition, protectedItem, operationCancelled, operationTimedOut
    case directUnavailable(String), directActivationFailed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "此系统构建尚未完成菜单栏兼容验证，或所需接口不可用。当前验证范围：macOS 26.6.2（25G83）。"
        case .permission: return "请先授予辅助功能权限，才能操作其他应用的菜单栏图标。"
        case .disappeared: return "这个图标已退出或发生变化，请重试。"
        case .busy: return "请先完成当前菜单栏操作。"
        case .operationCancelled: return "应用或桌面状态发生变化，已停止当前操作并展开菜单栏。请重试。"
        case .operationTimedOut: return "菜单操作超过两分钟，已展开菜单栏；请关闭原菜单后重试。"
        case .moveFailed: return "菜单栏操作未能完成，请展开菜单栏后重试。"
        case .directUnavailable(let reason): return reason
        case .directActivationFailed(let reason): return reason
        case .unsafePosition: return "菜单栏可见空间不足，已展开。请减少常驻系统图标后重试。"
        case .protectedItem: return "系统状态图标无法安全保留在常驻区，已展开。"
        }
    }
}

/// Version-gated, dynamically resolved WindowServer bridge. No private framework is linked.
/// This is an original implementation; the ABI is confined to this file.
final class MenuBarSystem {
    static let supportedBuilds: Set<String> = ["25G83"]
    static let currentBuild: String = {
        var size = 0
        guard sysctlbyname("kern.osversion",nil,&size,nil,0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating:0,count:size)
        guard sysctlbyname("kern.osversion",&bytes,&size,nil,0) == 0 else { return "unknown" }
        return String(cString:bytes)
    }()
    typealias MainConnection = @convention(c) () -> UInt32
    typealias WindowList = @convention(c) (UInt32, Int32, Int32, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<Int32>) -> Int32
    typealias WindowRect = @convention(c) (UInt32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
    private var handle: UnsafeMutableRawPointer?
    private var mainConnection: MainConnection?
    private var listWindows: WindowList?
    private var windowRect: WindowRect?
    private var owners: [CGWindowID:AccessibleMenuItem] = [:]
    private var ownWindows = Set<CGWindowID>()
    private var fingerprints: [CGWindowID:String] = [:]
    private var ownerLaunchDates: [CGWindowID:Date] = [:]
    private var ownershipRevision: UInt64 = 0
    private(set) var discardedOwnershipScans = 0
    var placementObserver: ((CGRect?,CGRect?) -> Void)?
    var available: Bool { Self.supportedBuilds.contains(Self.currentBuild) && mainConnection != nil && listWindows != nil && windowRect != nil }
    init() {
        guard Self.supportedBuilds.contains(Self.currentBuild),
              let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return }
        handle = library
        if let fn = dlsym(library,"CGSMainConnectionID") { mainConnection = unsafeBitCast(fn,to:MainConnection.self) }
        if let fn = dlsym(library,"CGSGetProcessMenuBarWindowList") { listWindows = unsafeBitCast(fn,to:WindowList.self) }
        if let fn = dlsym(library,"CGSGetScreenRectForWindow") { windowRect = unsafeBitCast(fn,to:WindowRect.self) }
    }
    deinit { if let handle { dlclose(handle) } }
    var sessionAllowsInput: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String:Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) != true &&
               (session[kCGSessionOnConsoleKey as String] as? Bool) == true
    }
    func frame(_ id: CGWindowID) -> CGRect? {
        guard available, let mainConnection, let windowRect else { return nil }
        var rect = CGRect.zero
        guard windowRect(mainConnection(),id,&rect) == 0, !rect.isEmpty, rect.width.isFinite else { return nil }
        return rect
    }
    func windowInfo(onScreenOnly: Bool = false) -> [[String: Any]] {
        CGWindowListCopyWindowInfo(onScreenOnly ? [.optionOnScreenOnly,.excludeDesktopElements] : [.optionAll,.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] ?? []
    }
    func entries() throws -> [MenuBarEntry] {
        guard available, let mainConnection, let listWindows else { throw MenuBarError.unavailable }
        var ids = [UInt32](repeating:0,count:2048), count: Int32 = 0
        let result = ids.withUnsafeMutableBufferPointer { listWindows(mainConnection(),0,Int32($0.count),$0.baseAddress!,&count) }
        guard result == 0, count >= 0, count < ids.count else { throw MenuBarError.unavailable }
        let info = Dictionary(windowInfo().compactMap { value -> (UInt32,[String:Any])? in
            guard let id = value[kCGWindowNumber as String] as? UInt32 else { return nil }; return (id,value)
        }, uniquingKeysWith: { first,_ in first })
        return ids.prefix(Int(count)).compactMap { id in
            guard let value = info[id], let pid = value[kCGWindowOwnerPID as String] as? Int32,
                  let rect = frame(id), let app = NSRunningApplication(processIdentifier:pid), !app.isTerminated else { return nil }
            let rawTitle = value[kCGWindowName as String] as? String ?? ""
            guard rawTitle != "Menubar" else { return nil }
            let hosted = app.bundleIdentifier == "com.apple.controlcenter"
            let flowmori = NSRunningApplication.runningApplications(withBundleIdentifier:ProductIdentity.bundleID).first
            let ownByTitle = (flowmori != nil && ["Flowmori.Main","Flowmori.CollectionDivider"].contains(rawTitle))
            let knownSystem = ["Clock","BentoBox-0","WiFi","Battery","Spotlight"].contains(rawTitle)
            let fingerprint = "\(pid)|\(app.launchDate?.timeIntervalSince1970 ?? 0)|\(rawTitle)"
            if fingerprints[id] != fingerprint || knownSystem {
                owners.removeValue(forKey:id)
                ownWindows.remove(id)
            }
            fingerprints[id] = fingerprint
            let own = ownWindows.contains(id) || ownByTitle
            let identity = owners[id].flatMap { cached -> AccessibleMenuItem? in
                guard let source = NSRunningApplication(processIdentifier:cached.owner.pid), !source.isTerminated,
                      source.bundleIdentifier == cached.owner.bundleID,
                      source.launchDate == ownerLaunchDates[id] else { return nil }
                return cached
            }
            let ownerPID = own ? (flowmori?.processIdentifier ?? ProcessInfo.processInfo.processIdentifier) : (identity?.owner.pid ?? (hosted && !knownSystem ? 0 : pid))
            let name = own ? "Flowmori" : (identity?.owner.name ?? (ownerPID == 0 ? "待识别图标" : app.localizedName ?? "应用 \(pid)"))
            let bundle = own ? ProductIdentity.bundleID : (identity?.owner.bundleID ?? (ownerPID == 0 ? "" : app.bundleIdentifier ?? ""))
            return MenuBarEntry(id:id,pid:pid,ownerPID:ownerPID,bundleID:bundle,name:name,
                                title:identity?.label ?? rawTitle,frame:rect,
                                supportedActions:identity?.actions ?? [])
        }.sorted { $0.frame.minX < $1.frame.minX }
    }
    func claimOwnStatusWindow(_ id:CGWindowID) { ownWindows.insert(id) }
    @MainActor func invalidateOwnershipScan() { ownershipRevision &+= 1 }
    @MainActor @discardableResult func refreshOwnership(priorityPID: pid_t? = nil) async -> Bool {
        guard AXIsProcessTrusted(), let initial = try? entries() else { return false }
        func candidates(_ entries: [MenuBarEntry]) -> [MenuWindowResolver.Candidate] {
            entries.map { .init(id:$0.id,pid:$0.pid,frame:$0.frame) }
        }
        let snapshot = MenuOwnershipSnapshot(revision:ownershipRevision,windows:candidates(initial))
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && $0.activationPolicy != .prohibited }
        let hosts: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.WindowManager"]
        let selected = priorityPID.map { pid in
            running.filter { $0.processIdentifier == pid || hosts.contains($0.bundleIdentifier ?? "") }
        } ?? running
        let apps = selected.map {
            MenuBarOwner(pid:$0.processIdentifier,bundleID:$0.bundleIdentifier ?? "",name:$0.localizedName ?? "应用")
        }
        let catalog = await Task.detached(priority:.utility) { MenuAccessibilityCatalog.scan(apps) }.value
        guard !Task.isCancelled, let windows = try? entries() else { return false }
        guard snapshot.isCurrent(revision:ownershipRevision,windows:candidates(windows)) else {
            discardedOwnershipScans += 1
            return false
        }
        for window in windows {
            let candidates = catalog.filter {
                MenuWindowResolver.matchesAccessibilityFrame($0.frame,window:window.frame)
            }
            // The rendering host can expose a duplicate AX node. Prefer the
            // original application's node when both point at the same window.
            let original = candidates.filter { $0.owner.pid != window.pid }
            let hosted = NSRunningApplication(processIdentifier:window.pid)?.bundleIdentifier == "com.apple.controlcenter"
            let matches = hosted ? original : (original.isEmpty ? candidates : original)
            let sourcePIDs = Set(matches.map { $0.owner.pid })
            if sourcePIDs.count == 1, let match = matches.first {
                owners[window.id] = match
                ownerLaunchDates[window.id] = NSRunningApplication(processIdentifier:match.owner.pid)?.launchDate
            } else if !MenuOwnerCachePolicy.keepCached(identityUnchanged:true,
                sourceAlive:owners[window.id].map { NSRunningApplication(processIdentifier:$0.owner.pid)?.isTerminated == false } ?? false,
                protectedSystem:window.protected, matchingOwners:sourcePIDs.count) {
                owners.removeValue(forKey:window.id); ownerLaunchDates.removeValue(forKey:window.id)
            }
            // An absent AX node is not evidence of a new owner. Hidden status
            // items can vanish from AX temporarily. Host identity and process
            // lifetime are checked in entries(); valid() still rechecks AX
            // immediately before every actual input.
        }
        let liveIDs = Set(windows.map(\.id))
        owners = owners.filter { liveIDs.contains($0.key) }
        ownerLaunchDates = ownerLaunchDates.filter { liveIDs.contains($0.key) }
        fingerprints = fingerprints.filter { liveIDs.contains($0.key) }
        ownWindows.formIntersection(liveIDs)
        return true
    }
    func visibleWindows(pid: pid_t) -> Set<UInt32> {
        let items = Set((try? entries().map(\.id)) ?? [])
        return Set(windowInfo(onScreenOnly:true).compactMap { item in
            guard (item[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let id = item[kCGWindowNumber as String] as? UInt32, !items.contains(id) else { return nil }
            return id
        })
    }
    func valid(_ entry: MenuBarEntry) -> Bool {
        guard let app = NSRunningApplication(processIdentifier:entry.ownerPID), !app.isTerminated,
              app.bundleIdentifier == entry.bundleID, let currentFrame = frame(entry.id),
              (try? entries().contains { $0.id == entry.id && $0.pid == entry.pid && $0.ownerPID == entry.ownerPID && $0.bundleID == entry.bundleID }) == true else { return false }
        if entry.pid == entry.ownerPID { return true }
        // Hosted window IDs can be recycled. Recheck the original application's
        // current AX item before every synthetic input, not only its cached PID.
        let owner = MenuBarOwner(pid:entry.ownerPID,bundleID:entry.bundleID,name:entry.name)
        return MenuAccessibilityCatalog.scan([owner]).contains {
            MenuWindowResolver.matchesAccessibilityFrame($0.frame,window:currentFrame)
        }
    }
    private func event(_ type: CGEventType, entry: MenuBarEntry, point: CGPoint, command: Bool, button: CGMouseButton = .left) -> CGEvent? {
        guard let source = CGEventSource(stateID:.hidSystemState),
              let event = CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:point,mouseButton:button) else { return nil }
        event.flags = command ? .maskCommand : []
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer,value:Int64(entry.id))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value:Int64(entry.id))
        // The status-item reorder path uses the native event window number.
        // Keep this undocumented field inside the macOS-26 compatibility layer.
        if command, let windowNumber = CGEventField(rawValue:0x33) { event.setIntegerValueField(windowNumber,value:Int64(entry.id)) }
        event.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(entry.pid))
        event.setIntegerValueField(.eventSourceUserData,value:0x464D4F52)
        event.setIntegerValueField(.mouseEventClickState,value:1)
        return event
    }
    @MainActor func drag(_ entry: MenuBarEntry, to point: CGPoint) async throws {
        guard AXIsProcessTrusted() else { throw MenuBarError.permission }
        guard sessionAllowsInput else { throw MenuBarError.operationCancelled }
        guard valid(entry), let original = frame(entry.id) else { throw MenuBarError.disappeared }
        let start = CGPoint(x:original.midX,y:original.midY)
        guard let down = event(.leftMouseDown,entry:entry,point:start,command:true),
              let up = event(.leftMouseUp,entry:entry,point:point,command:true) else { throw MenuBarError.moveFailed }
        invalidateOwnershipScan()
        down.post(tap:.cgSessionEventTap)
        // Always release the synthetic button, including cancellation/error paths.
        defer { up.post(tap:.cgSessionEventTap); invalidateOwnershipScan() }
        try await Task.sleep(for:.milliseconds(70))
        // A native drag includes motion events; down/up alone can snap to the
        // wrong insertion slot when a notch causes neighboring items to reflow.
        for step in 1...8 {
            try Task.checkCancellation()
            guard sessionAllowsInput else { throw MenuBarError.operationCancelled }
            let fraction = CGFloat(step)/8
            let location = CGPoint(x:start.x+(point.x-start.x)*fraction,y:start.y+(point.y-start.y)*fraction)
            guard let motion = event(.leftMouseDragged,entry:entry,point:location,command:true) else { throw MenuBarError.moveFailed }
            motion.post(tap:.cgSessionEventTap)
            try await Task.sleep(for:.milliseconds(20))
        }
    }
    @MainActor func waitForStableLayout() async throws {
        // Let the initial layout transaction begin before sampling its animation.
        try await Task.sleep(for:.milliseconds(200))
        var stability = MenuLayoutStability()
        for _ in 0..<30 {
            try Task.checkCancellation()
            guard sessionAllowsInput else { throw MenuBarError.operationCancelled }
            let windows = try entries().map { MenuWindowResolver.Candidate(id:$0.id,pid:$0.pid,frame:$0.frame) }
            if stability.observe(windows) { return }
            try await Task.sleep(for:.milliseconds(100))
        }
        throw MenuBarError.moveFailed
    }
    @MainActor func drag(_ entry: MenuBarEntry, before neighborID: CGWindowID) async throws {
        guard AXIsProcessTrusted() else { throw MenuBarError.permission }
        guard sessionAllowsInput else { throw MenuBarError.operationCancelled }
        guard entry.id != neighborID else { throw MenuBarError.moveFailed }
        var placement = MenuPlacementState()
        while true {
            try Task.checkCancellation()
            guard valid(entry) else { throw MenuBarError.disappeared }
            let sourceFrame = frame(entry.id), neighborFrame = frame(neighborID)
            placementObserver?(sourceFrame,neighborFrame)
            switch placement.next(source:sourceFrame,neighbor:neighborFrame) {
            case .complete: return
            case .failed: throw MenuBarError.moveFailed
            case .move(let point):
                try await drag(entry,to:point)
                try await waitForStableLayout()
            }
        }
    }
    @MainActor func click(_ entry: MenuBarEntry, right: Bool) async throws {
        guard sessionAllowsInput else { throw MenuBarError.operationCancelled }
        guard AXIsProcessTrusted(), valid(entry), let rect = frame(entry.id) else { throw MenuBarError.disappeared }
        let point = CGPoint(x:rect.midX,y:rect.midY)
        guard let down = event(right ? .rightMouseDown : .leftMouseDown,entry:entry,point:point,command:false,button:right ? .right : .left),
              let up = event(right ? .rightMouseUp : .leftMouseUp,entry:entry,point:point,command:false,button:right ? .right : .left) else { throw MenuBarError.moveFailed }
        down.post(tap:.cghidEventTap)
        try? await Task.sleep(for:.milliseconds(50))
        up.post(tap:.cghidEventTap)
    }
}

@MainActor final class MenuLayoutDeferral {
    private(set) var isSettling = false
    private var task: Task<Void,Never>?
    var onSettled: (() -> Void)?
    func changed() {
        task?.cancel(); isSettling = true
        task = Task { [weak self] in
            do { try await Task.sleep(for:.milliseconds(250)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.isSettling = false; self.task = nil; self.onSettled?()
        }
    }
    func cancel() { task?.cancel(); task = nil; isSettling = false }
    deinit { task?.cancel() }
}

@MainActor final class MenuBarManager: ObservableObject {
    @Published private(set) var items: [MenuBarEntry] = []
    @Published private(set) var message = "点击「收纳全部」，自动整理可管理的应用图标。"
    @Published private(set) var expanded = true
    @Published private(set) var operating = false
    let system = MenuBarSystem()
    private let settings: Settings
    private let divider: NSStatusItem
    private let control: NSStatusItem
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var transaction = MenuOperationState()
    private var operation: Task<Void,Never>?
    private var lastOperationOutcome = "none"
    private var collectionStage = "idle"
    private var operationStage = "idle"
    private var returnDetail = ""
    private var returnPlacementTrace: [[String:Any]] = []
    private var lastLifecycleEvent = "none"
    private var recoveryFile: URL
    private var allowCollapse = false
    private var suspended = false
    private var collectedIDs = Set<CGWindowID>()
    private var collectedFingerprints: [CGWindowID:String] = [:]
    private var wantsCollection = false
    private var needsCollection = false
    private var ownershipTask: Task<Void,Never>?
    private var priorityLaunchPID: pid_t?
    private var holdMessage = false
    private var nextOwnershipRefresh = Date.distantPast
    private let layout = MenuLayoutDeferral()
    var onChanged: (() -> Void)?
    var onMessage: ((String) -> Void)?
    var closePanel: (() -> Void)?
    private var inlinePresenter: NativeInlineMenuPresenter?
    private var inlineRoot: [InlineMenuNode] = []
    private var inlineEntry: MenuBarEntry?
    private var menuAnchor = NSPoint.zero
    private var preparingInline = false
    private var directFailureUntil = Date.distantPast
    private var inlineCache: [CGWindowID: CachedInlineMenu] = [:]
    private var unavailableCache: [CGWindowID: UnavailableInlineMenu] = [:]
    private struct CachedInlineMenu {
        let nodes: [InlineMenuNode]
        let createdAt: Date
        let ownerPID: pid_t
        let launchDate: Date?
    }
    private struct UnavailableInlineMenu {
        let message: String
        let until: Date
        let ownerPID: pid_t
        let launchDate: Date?
    }
    init(settings: Settings, control: NSStatusItem, dataDirectory: URL) {
        self.settings = settings; self.control = control
        recoveryFile = dataDirectory.appendingPathComponent("menu-recovery.json")
        divider = NSStatusBar.system.statusItem(withLength:18)
        divider.autosaveName = "Flowmori.CollectionDivider"
        divider.button?.title = "│"
        divider.button?.toolTip = "点击展开／收纳全部，无需拖动分隔符。"
        divider.button?.target = self; divider.button?.action = #selector(toggleExpanded)
        layout.onSettled = { [weak self] in self?.refresh() }
        divider.isVisible = settings.menuEnabled
        wantsCollection = settings.menuEnabled; needsCollection = settings.menuEnabled
        if FileManager.default.fileExists(atPath:recoveryFile.path) {
            settings.menuEnabled = false
            wantsCollection = false; needsCollection = false
            divider.isVisible = false
            message = "上次操作未完成。已暂停收纳，请检查图标位置后重新启用。"
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.willSleepNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lastLifecycleEvent = name.rawValue
                    if name == NSWorkspace.didLaunchApplicationNotification,
                       let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                        let pid = app.processIdentifier
                        self.priorityLaunchPID = pid
                        Task { [weak self] in
                            try? await Task.sleep(for:.milliseconds(250))
                            guard let self else { return }
                            self.priorityLaunchPID = pid
                            self.nextOwnershipRefresh = .distantPast
                            self.refresh()
                        }
                    }
                    self.system.invalidateOwnershipScan()
                    self.clearInlineCaches()
                    // App launches, app exits, sleep/wake, and Space switches are
                    // routine while the user works. Re-scan ownership in place;
                    // never expand the menu bar merely because one of them fired.
                    // refresh() only expands if the actual layout is unusable.
                    self.operation?.cancel()
                    self.nextOwnershipRefresh = .distantPast
                    self.refresh()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }; self.operation?.cancel(); self.showAll(); self.refresh()
                self.system.invalidateOwnershipScan()
                self.clearInlineCaches()
                self.lastLifecycleEvent = "screenParametersChanged"
                self.message = "显示器已变化，收纳已展开。确认图标位置后可再次收起。"
            }
        })
        timer = Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    var supported: Bool { system.available }
    private func windowID(for item:NSStatusItem) -> CGWindowID? {
        guard let window = item.button?.window, let primary = NSScreen.screens.first,
              let entries = try? system.entries() else { return nil }
        let frame = window.frame
        let quartz = CGRect(x:frame.minX,y:primary.frame.maxY-frame.maxY,width:frame.width,height:frame.height)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates = entries.filter { $0.pid == ownPID || NSRunningApplication(processIdentifier:$0.pid)?.bundleIdentifier == "com.apple.controlcenter" }
        // AppKit supplies our exact status-item frame even when WindowServer
        // titles are unavailable. The unique hosted window at that frame is ours.
        let resolved = MenuWindowResolver.resolve(appKitNumber:window.windowNumber,frame:quartz,pid:ownPID,
            candidates:candidates.map { .init(id:$0.id,pid:ownPID,frame:$0.frame) })
        if let resolved { system.claimOwnStatusWindow(resolved) }
        return resolved
    }
    private var dividerID: UInt32? { windowID(for:divider) }
    private var controlID: UInt32? { windowID(for:control) }
    func diagnosticSnapshot() -> [String:Any] {
        let own = (try? system.entries().filter { $0.ownerPID == ProcessInfo.processInfo.processIdentifier }) ?? []
        return ["systemBuild":MenuBarSystem.currentBuild,"message":message,
                "lastOperationOutcome":lastOperationOutcome,"collectionStage":collectionStage,"operationStage":operationStage,
                "returnDetail":returnDetail,"returnPlacementTrace":returnPlacementTrace,"lastLifecycleEvent":lastLifecycleEvent,
                "discardedOwnershipScans":system.discardedOwnershipScans,
                "controlAppKitNumber":control.button?.window?.windowNumber ?? -1,
                "dividerAppKitNumber":divider.button?.window?.windowNumber ?? -1,
                "controlFrame":control.button?.window.map { NSStringFromRect($0.frame) } ?? "",
                "dividerFrame":divider.button?.window.map { NSStringFromRect($0.frame) } ?? "",
                "controlResolvedID":controlID ?? 0,"dividerResolvedID":dividerID ?? 0,
                "ownWindows":own.map { ["id":$0.id,"frame":NSStringFromRect($0.frame)] as [String:Any] }]
    }
    func enable(_ enabled: Bool) {
        if operating { message = "请先关闭当前图标的菜单，再修改收纳设置。"; return }
        system.invalidateOwnershipScan()
        settings.menuEnabled = enabled; divider.isVisible = enabled
        allowCollapse = false; suspended = false; showAll()
        if enabled {
            try? FileManager.default.removeItem(at:recoveryFile)
            message = "正在准备自动收纳…"
            wantsCollection = true; needsCollection = true
        } else {
            wantsCollection = false; needsCollection = false
            collectedIDs.removeAll(); collectedFingerprints.removeAll()
            message = "收纳已暂停，所有图标恢复系统布局。"
        }
        refresh()
    }
    func refresh() {
        let pinned = holdMessage ? message : nil
        defer { if let pinned { message = pinned } }
        guard inlinePresenter == nil, !operating, !layout.isSettling else { return }
        // A locked screen must not expand the menu bar behind the lock screen.
        guard system.sessionAllowsInput else { return }
        allowCollapse = false
        guard settings.menuEnabled, !suspended else { if !items.isEmpty { items = [] }; return }
        guard system.available else { fail(MenuBarError.unavailable); return }
        guard AXIsProcessTrusted() else {
            showAll(); message = MenuBarError.permission.localizedDescription; return
        }
        if ownershipTask == nil, Date() >= nextOwnershipRefresh {
            nextOwnershipRefresh = Date().addingTimeInterval(10)
            let priorityPID = priorityLaunchPID
            priorityLaunchPID = nil
            ownershipTask = Task { [weak self] in
                guard let self else { return }
                let accepted = await self.system.refreshOwnership(priorityPID:priorityPID)
                guard !Task.isCancelled else { return }
                self.ownershipTask = nil
                // A stale scan must not erase verified owners. Retry on the
                // next refresh after the current layout transition settles.
                if !accepted { self.nextOwnershipRefresh = Date().addingTimeInterval(0.3) }
                self.refresh()
            }
        }
        do {
            let all = try system.entries()
            guard let id = dividerID, let bar = system.frame(id), let anchorID = controlID,
                  let anchor = system.frame(anchorID) else {
                showAll(); message = "暂时无法确认菜单栏图标位置，已展开。等待系统布局后自动重试。"; return
            }
            if wantsCollection {
                pruneCollected(all)
                let newItems = all.filter { $0.ownerPID != ownPIDForCollection && $0.ownershipResolved && !$0.protected && !collectedIDs.contains($0.id) && abs($0.frame.midY-anchor.midY) < 3 }
                if !newItems.isEmpty && needsCollection == false {
                    // Once the user has opted into collection, new status items
                    // should join it without a manual expand/re-collect cycle.
                    // Only do this while collapsed; an explicitly expanded bar
                    // is left alone.
                    if !expanded, operation == nil {
                        showPending(newItems)
                        message = "发现 \(newItems.count) 个新图标，正在收纳…"
                        collectAll()
                        return
                    }
                    message = "发现 \(newItems.count) 个新图标，点击「收纳全部」以收纳。"
                }
            }
            if needsCollection && ownershipTask == nil {
                collectAll(); return
            }
            guard bar.maxX <= anchor.minX + 2 else {
                showAll(); message = "点击「收纳全部」自动整理菜单栏。"; return
            }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            guard let screen = control.button?.window?.screen, let primary = NSScreen.screens.first else { throw MenuBarError.unsafePosition }
            let screenRect = CGRect(x:screen.frame.minX,y:primary.frame.maxY-screen.frame.maxY,width:screen.frame.width,height:screen.frame.height)
            // Off-screen coordinates can overlap another monitor after collapse. Capture
            // membership while expanded and only follow those window IDs while hidden.
            let hidden = all.filter {
                guard $0.ownerPID != ownPID, $0.frame.maxX <= bar.minX + 2, abs($0.frame.midY-anchor.midY) < 3 else { return false }
                return expanded ? (screenRect.contains(CGPoint(x:$0.frame.midX,y:$0.frame.midY)) || collectedIDs.contains($0.id)) : collectedIDs.contains($0.id)
            }
            if expanded { collectedIDs = Set(hidden.map(\.id)) }
            guard hidden.allSatisfy(\.ownershipResolved) else {
                if items != hidden { items = hidden }
                message = "正在识别图标所属应用…"
                return
            }
            if hidden.contains(where:\.protected) { fail(MenuBarError.protectedItem); return }
            if items != hidden { items = hidden }
            allowCollapse = true
            if expanded && hidden.isEmpty { message = "暂无可管理图标，点击「收纳全部」重新识别。" }
            else { message = expanded ? "已展开 · \(hidden.count) 个图标可收纳" : "已收纳 \(hidden.count) 个图标" }
            onChanged?()
        } catch { fail(error) }
    }
    private var ownPIDForCollection: pid_t { ProcessInfo.processInfo.processIdentifier }
    /// New status items are visible before the collection pass has finished
    /// moving them. Show them in the panel immediately so the user does not
    /// have to wait for a full expand/re-collect cycle to see the icon.
    private func showPending(_ newItems:[MenuBarEntry]) {
        var updated = items
        let existing = Set(updated.map(\.id))
        updated.append(contentsOf:newItems.filter { !existing.contains($0.id) })
        guard updated != items else { return }
        updated.sort { $0.frame.minX < $1.frame.minX }
        items = updated
        inlineDebugLog("pending new ids=\(newItems.map { Int($0.id) }) panel=\(updated.count)")
        onChanged?()
    }
    private func collectionFingerprint(_ entry:MenuBarEntry) -> String {
        let launch = NSRunningApplication(processIdentifier:entry.ownerPID)?.launchDate?.timeIntervalSince1970 ?? 0
        return "\(entry.ownerPID)|\(entry.bundleID)|\(launch)"
    }
    private func pruneCollected(_ all:[MenuBarEntry]) {
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id,$0) })
        for id in collectedIDs {
            guard let entry = byID[id] else {
                collectedIDs.remove(id); collectedFingerprints.removeValue(forKey:id); continue
            }
            // Window IDs can be recycled after an app exits. A different owner
            // on the same ID is a new item, not a collected one.
            if entry.ownerPID > 0, collectedFingerprints[id] != collectionFingerprint(entry) {
                collectedIDs.remove(id); collectedFingerprints.removeValue(forKey:id)
            }
        }
    }
    @objc func toggleExpanded() {
        if expanded { collectAll() }
        else { wantsCollection = false; needsCollection = false; showAll() }
    }
    /// A status item behind the notch cannot receive a reliable drag. Reinsert
    /// our own AppKit item using its saved position, preserving button handlers.
    /// This preference mechanism is confined to the supported-build adapter.
    private func placeOwn(_ item: NSStatusItem, before neighborID: CGWindowID) async throws {
        guard system.sessionAllowsInput, let name = item.autosaveName else { throw MenuBarError.unsafePosition }
        if let id = windowID(for:item), let rect = system.frame(id), isReachable(rect) {
            // Already visible: retain the existing window and its identity.
        } else {
            system.invalidateOwnershipScan()
            item.isVisible = false
            defer { item.isVisible = true; system.invalidateOwnershipScan() }
            try await system.waitForStableLayout()
            guard system.sessionAllowsInput else { throw MenuBarError.operationCancelled }
            // Preferred Position is a system insertion hint, not a reliable
            // global coordinate. Zero restores a visible slot; reconcile below.
            UserDefaults.standard.set(0,forKey:"NSStatusItem Preferred Position \(name)")
            item.isVisible = true
            try await system.waitForStableLayout()
        }
        guard let id = windowID(for:item), let rect = system.frame(id), isReachable(rect),
              let entry = try system.entries().first(where: { $0.id == id }) else { throw MenuBarError.unsafePosition }
        try await system.drag(entry,before:neighborID)
    }
    /// Explicit user exit for icons that cannot be activated directly. This is
    /// never an automatic fallback for a failed in-panel activation.
    func expandMenuBar() {
        guard !operating else { onMessage?(MenuBarError.busy.localizedDescription); return }
        holdMessage = false
        closePanel?()
        showAll()
        message = "已展开菜单栏，请直接在菜单栏操作图标。"
        onMessage?(message)
    }
    /// User-requested/global organization is separate from temporary menu restore.
    func collectAll() {
        guard !operating, system.available, system.sessionAllowsInput else { return }
        holdMessage = false
        suspended = false
        if !settings.menuEnabled { enable(true); return }
        guard AXIsProcessTrusted() else { message = MenuBarError.permission.localizedDescription; return }
        wantsCollection = true; needsCollection = false; operating = true
        ownershipTask?.cancel(); ownershipTask = nil
        showAll()
        message = "正在整理全部可管理图标…"
        collectionStage = "scan"
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await system.waitForStableLayout()
                guard await system.refreshOwnership(), let originalSplitID = dividerID, let originalMainID = controlID else { throw MenuBarError.disappeared }
                var all = try system.entries()
                let plan = MenuCollectionPlan(items:all.map {
                    .init(id:$0.id,frame:$0.frame,manageable:$0.ownerPID != self.ownPIDForCollection && $0.ownershipResolved && !$0.protected)
                },control:originalMainID,divider:originalSplitID)
                let targets = plan.targets.compactMap { id in all.first { $0.id == id } }
                let journal: [String:Any] = ["operation":"collectAll", "windows":plan.targets,
                                            "created":Date().timeIntervalSince1970]
                try JSONSerialization.data(withJSONObject:journal).write(to:recoveryFile,options:.atomic)
                collectionStage = "control"
                if let firstRetained = plan.retained.first {
                    try await placeOwn(control,before:firstRetained)
                }
                guard let mainID = controlID else { throw MenuBarError.disappeared }
                collectionStage = "divider"
                try await placeOwn(divider,before:mainID)
                guard let splitID = dividerID else { throw MenuBarError.disappeared }
                for target in targets {
                    collectionStage = "item-\(target.id)"
                    try Task.checkCancellation()
                    // Moving our divider already collects all icons to its left.
                    // Do not drag those icons, especially ones under the notch.
                    if let rect = system.frame(target.id), let bar = system.frame(splitID), rect.maxX <= bar.minX+3 { continue }
                    try await system.drag(target,before:splitID)
                }
                collectionStage = "verify"
                all = try system.entries()
                guard let bar = system.frame(splitID), let controlFrame = system.frame(mainID),
                      bar.maxX <= controlFrame.minX + 3,
                      all.filter({ plan.retained.contains($0.id) }).allSatisfy({ $0.frame.minX >= bar.maxX-3 }),
                      targets.allSatisfy({ target in all.contains { $0.id == target.id && $0.frame.maxX <= bar.minX+3 } }) else { throw MenuBarError.moveFailed }
                collectedIDs = Set(targets.map(\.id))
                collectedFingerprints = Dictionary(uniqueKeysWithValues: targets.map { ($0.id,self.collectionFingerprint($0)) })
                operating = false
                collapse()
                operating = true
                guard !expanded || targets.isEmpty else { throw MenuBarError.moveFailed }
                // The divider's left edge may be off-screen when collapsed;
                // only the actual Flowmori action button must remain reachable.
                try await system.waitForStableLayout()
                guard let visible = system.frame(mainID), isReachable(visible) else { throw MenuBarError.unsafePosition }
                try FileManager.default.removeItem(at:recoveryFile)
                lastOperationOutcome = "collectedAll"
                collectionStage = "completed"
            } catch is CancellationError { lastOperationOutcome = "collectionCancelled"; fail(MenuBarError.operationCancelled) }
            catch { lastOperationOutcome = "collectionFailed"; fail(error) }
            operating = false; operation = nil; refresh()
        }
    }
    func showAll() {
        guard !expanded || divider.length != 18 else { return }
        system.invalidateOwnershipScan(); layout.changed(); divider.length = 18; expanded = true; onChanged?()
    }
    func collapse() {
        guard settings.menuEnabled, !operating, !suspended, !layout.isSettling else { return }
        refresh()
        guard allowCollapse, AXIsProcessTrusted(), !items.isEmpty else { return }
        let maxWidth = NSScreen.screens.map(\.frame.width).max() ?? 2000
        system.invalidateOwnershipScan(); layout.changed(); divider.length = min(10000,max(500,maxWidth * 2)); expanded = false
        onChanged?()
    }
    private func fail(_ error: Error) {
        showAll(); suspended = true; allowCollapse = false; wantsCollection = false; needsCollection = false
        collectedIDs.removeAll(); collectedFingerprints.removeAll()
        message = error.localizedDescription; onMessage?(message)
    }
    func activate(_ entry: MenuBarEntry, right: Bool) {
        inlineDebugLog("activate id=\(entry.id) name=\(entry.name) right=\(right) operating=\(operating) presenter=\(inlinePresenter != nil) resolved=\(entry.ownershipResolved)")
        guard inlinePresenter == nil else { onMessage?("请先关闭已打开的菜单。"); return }
        guard !operating, transaction.begin(entry.id) else { onMessage?(MenuBarError.busy.localizedDescription); return }
        holdMessage = false
        directFailureUntil = .distantPast
        menuAnchor = NSEvent.mouseLocation
        let name = entry.name.isEmpty ? entry.title : entry.name
        guard !entry.protected else { transaction.fail(); onMessage?(MenuBarError.protectedItem.localizedDescription); return }
        guard entry.ownershipResolved else { transaction.fail(); onMessage?("正在识别「\(name)」所属应用，请稍后重试。"); return }
        operating = true
        lastOperationOutcome = "running"
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performDirect(entry,right:right)
                self.lastOperationOutcome = self.inlinePresenter == nil ? "completed" : "panelMenu"
            } catch is CancellationError {
                self.finishIfSourceTerminated(entry:entry,name:name)
            } catch MenuBarError.operationCancelled {
                self.finishIfSourceTerminated(entry:entry,name:name)
            } catch MenuBarError.operationTimedOut {
                self.lastOperationOutcome = "timedOut"; self.transaction.fail(); self.fail(MenuBarError.operationTimedOut)
            } catch {
                self.lastOperationOutcome = "failed"; self.transaction.fail(); self.failDirect(error)
            }
            self.transaction.finish()
            self.operating = self.inlinePresenter != nil
            self.operation = nil
            if self.inlinePresenter == nil { self.refresh() }
        }
    }
    /// Quitting the source app from its own menu is a normal completion, not a
    /// failed layout operation. Expanding here surprises the user and can leave
    /// the rest of the bar exposed for an action they initiated.
    private func finishIfSourceTerminated(entry:MenuBarEntry,name:String) {
        guard sourceTerminated(entry.ownerPID) else {
            lastOperationOutcome = "cancelled"
            transaction.fail()
            fail(MenuBarError.operationCancelled)
            return
        }
        lastOperationOutcome = "sourceTerminated"
        transaction.finish()
        inlinePresenter?.cancel()
        inlinePresenter = nil; inlineRoot = []; inlineEntry = nil
        holdMessage = false
        operationStage = "source-terminated"
        message = "「\(name)」已退出。"
        operating = false
        closePanel?()
    }
    /// Open the live AX menu, snapshot its items, and dismiss the off-screen
    /// native menu before presenting the same items inside the collection
    /// panel. Status icons never move and the menu bar never expands.
    private func performDirect(_ entry: MenuBarEntry,right:Bool) async throws {
        operationStage = right ? "panel-right" : "panel-left"
        guard AXIsProcessTrusted(), system.available else { throw MenuBarError.permission }
        guard system.sessionAllowsInput else { throw MenuBarError.operationCancelled }
        guard let current = try system.entries().first(where: {
            $0.id == entry.id && $0.ownerPID == entry.ownerPID && $0.bundleID == entry.bundleID
        }) else { throw MenuBarError.disappeared }
        let name = current.name.isEmpty ? current.title : current.name
        if let unavailable = cachedUnavailable(for:current) {
            throw MenuBarError.directUnavailable(unavailable)
        }
        if let cached = cachedInlineMenu(for:current) {
            returnDetail = "panel=\(right ? "right" : "left") cache=hit nodes=\(cached.count)"
            operationStage = "panel-menu"
            presentInlineMenu(cached,entry:current)
            return
        }
        let owner = MenuBarOwner(pid:current.ownerPID,bundleID:current.bundleID,name:current.name)
        let frame = current.frame
        let label = current.title
        let before = popoverWindows(current)
        preparingInline = true
        defer { preparingInline = false }
        holdMessage = true
        message = "正在读取「\(name)」的菜单…"
        let request = InlinePreparationRequest()
        defer { request.cancel() }
        DispatchQueue.global(qos:.userInitiated).async {
            request.complete(MenuAccessibilityCatalog.prepare(owner:owner,frame:frame,label:label,right:right,request:request))
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var candidateWindows = Set<UInt32>()
        var candidateSince = ProcessInfo.processInfo.systemUptime
        var detectedPopover = Set<UInt32>()
        var observedWindows = Set<UInt32>()
        while request.read() == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            guard system.sessionAllowsInput else { throw MenuBarError.operationCancelled }
            let windows = popoverWindows(current).subtracting(before)
            observedWindows.formUnion(windows)
            if windows != candidateWindows {
                candidateWindows = windows
                candidateSince = ProcessInfo.processInfo.systemUptime
            }
            if !windows.isEmpty, ProcessInfo.processInfo.systemUptime - candidateSince >= 0.3 {
                detectedPopover = windows
                closePanel?()
                break
            }
            try await Task.sleep(for:.milliseconds(50))
        }
        let preparation = detectedPopover.isEmpty ? request.read() : nil
        request.cancel()
        let resolvedPreparation = preparation ?? InlineMenuPreparation(nodes:[],action:"",supported:[],error:.cannotComplete,failure:.noMenu)
        try Task.checkCancellation()
        guard system.sessionAllowsInput else { throw MenuBarError.operationCancelled }
        let fallback = right && resolvedPreparation.action != "AXShowMenu"
        returnDetail = "panel=\(right ? "right" : "left") action=\(resolvedPreparation.action) ax=\(resolvedPreparation.error.rawValue) supported=\(resolvedPreparation.supported)"
        if fallback { returnDetail += " rightFallback=AXPress" }
        switch resolvedPreparation.failure {
        case .some(.cancelled):
            throw MenuBarError.operationCancelled
        case .some(.unavailable):
            let text = "「\(name)」不支持在收纳盒内打开菜单。请点击「展开菜单栏」后手动操作。"
            cacheUnavailable(text,for:current)
            throw MenuBarError.directUnavailable(text)
        case .some(.emptyMenu):
            let text = "「\(name)」的菜单没有可在收纳盒内显示的项目。"
            cacheUnavailable(text,for:current)
            throw MenuBarError.directActivationFailed(text)
        case .some(.noMenu):
            var opened = detectedPopover.union(popoverWindows(current).subtracting(before))
            if !opened.isEmpty {
                // A source menu window can outlive AXCancel for a fraction of a
                // second. Only treat a persistent new window as a real popover.
                try await Task.sleep(for:.milliseconds(300))
                guard system.sessionAllowsInput else { throw MenuBarError.operationCancelled }
                opened.formIntersection(popoverWindows(current))
            }
            guard !opened.isEmpty else {
                // A quick user dismissal may happen while AX is still reading.
                // An observed popover still completes the interaction.
                if !observedWindows.isEmpty {
                    closePanel?()
                    operationStage = "direct-completed"
                    return
                }
                let text = "「\(name)」没有显示可访问的菜单或弹窗。"
                cacheUnavailable(text,for:current)
                throw MenuBarError.directActivationFailed(text)
            }
            closePanel?()
            operationStage = "direct-menu-open"
            let deadline = Date().addingTimeInterval(120)
            while !opened.isEmpty && !opened.isDisjoint(with:popoverWindows(current)) {
                try Task.checkCancellation()
                guard AXIsProcessTrusted() else { throw MenuBarError.permission }
                guard system.sessionAllowsInput else { throw MenuBarError.operationCancelled }
                guard Date() < deadline else { throw MenuBarError.operationTimedOut }
                if sourceTerminated(current.ownerPID) {
                    throw MenuBarError.operationCancelled
                }
                try await Task.sleep(for:.milliseconds(250))
            }
            if sourceTerminated(current.ownerPID) {
                throw MenuBarError.operationCancelled
            }
            operationStage = "direct-completed"
            return
        case .none:
            break
        }
        cacheInlineMenu(resolvedPreparation.nodes,for:current)
        operationStage = "panel-menu"
        presentInlineMenu(resolvedPreparation.nodes,entry:current)
    }
    private func presentInlineMenu(_ nodes:[InlineMenuNode],entry:MenuBarEntry) {
        inlineRoot = nodes; inlineEntry = entry
        lastOperationOutcome = "panelMenu"; message = "菜单已打开。"
        let presenter = NativeInlineMenuPresenter()
        inlinePresenter = presenter
        presenter.present(nodes:nodes,at:menuAnchor,onSelect:{ [weak self] path in
            self?.performInline(path)
        },onCancel:{ [weak self] in
            self?.inlineMenuClosed()
        })
    }
    private func launchDate(for pid:pid_t) -> Date? {
        NSRunningApplication(processIdentifier:pid)?.launchDate
    }
    private func cachedInlineMenu(for entry:MenuBarEntry) -> [InlineMenuNode]? {
        guard let cached = inlineCache[entry.id] else { return nil }
        guard cached.ownerPID == entry.ownerPID, cached.launchDate == launchDate(for:entry.ownerPID),
              Date().timeIntervalSince(cached.createdAt) < 10 else {
            inlineCache.removeValue(forKey:entry.id)
            return nil
        }
        return cached.nodes
    }
    private func cacheInlineMenu(_ nodes:[InlineMenuNode],for entry:MenuBarEntry) {
        guard !nodes.isEmpty else { return }
        inlineCache[entry.id] = CachedInlineMenu(nodes:nodes,createdAt:Date(),
            ownerPID:entry.ownerPID,launchDate:launchDate(for:entry.ownerPID))
    }
    private func cachedUnavailable(for entry:MenuBarEntry) -> String? {
        guard let cached = unavailableCache[entry.id] else { return nil }
        guard cached.ownerPID == entry.ownerPID, cached.launchDate == launchDate(for:entry.ownerPID),
              cached.until > Date() else {
            unavailableCache.removeValue(forKey:entry.id)
            return nil
        }
        return cached.message
    }
    private func cacheUnavailable(_ message:String,for entry:MenuBarEntry) {
        unavailableCache[entry.id] = UnavailableInlineMenu(message:message,
            until:Date().addingTimeInterval(5),ownerPID:entry.ownerPID,launchDate:launchDate(for:entry.ownerPID))
    }
    private func clearInlineCache(for id:CGWindowID) {
        inlineCache.removeValue(forKey:id)
        unavailableCache.removeValue(forKey:id)
    }
    private func clearInlineCaches() {
        inlineCache.removeAll()
        unavailableCache.removeAll()
    }
    private func performInline(_ path:[Int]) {
        inlineDebugLog("performInline called path=\(path) entry=\(inlineEntry != nil) root=\(inlineRoot.count)")
        guard let entry = inlineEntry, let expected = InlineMenuSelection.levels(nodes:inlineRoot,path:path) else { return }
        clearInlineCache(for:entry.id)
        var nodes = inlineRoot
        var title = entry.name.isEmpty ? entry.title : entry.name
        for (depth,index) in path.enumerated() {
            guard index >= 0, index < nodes.count else { return }
            let node = nodes[index]
            guard node.enabled, !node.isSeparator else { return }
            title = node.title.isEmpty ? title : node.title
            if depth == path.count - 1, node.children.isEmpty {
                let owner = MenuBarOwner(pid:entry.ownerPID,bundleID:entry.bundleID,name:entry.name)
                inlineDebugLog("performInline path=\(path) owner=\(owner.name) frame=\(entry.frame)")
                operating = true
                operationStage = "panel-action"
                Task.detached { [weak self] in
                    try? await Task.sleep(for:.milliseconds(200))
                    let error = MenuAccessibilityCatalog.press(owner:owner,frame:entry.frame,label:entry.title,path:path,expected:expected)
                    inlineDebugLog("source press path=\(path) error=\(error.rawValue)")
                    await self?.finishInlineAction(error:error,title:title)
                }
                return
            }
            nodes = node.children
        }
    }
    private func inlineMenuClosed() {
        guard inlinePresenter != nil else { return }
        inlinePresenter = nil; inlineRoot = []; inlineEntry = nil
        holdMessage = false
        message = "已关闭菜单。"; operating = false; operationStage = "panel-menu"
        transaction.finish()
        refresh()
    }
    private func finishInlineAction(error:AXError,title:String) {
        if let id = inlineEntry?.id { clearInlineCache(for:id) }
        guard error == .success else {
            inlinePresenter = nil
            inlineRoot = []; inlineEntry = nil
            holdMessage = true
            operationStage = "panel-unavailable"
            message = "菜单项「\(title)」执行失败（\(error.rawValue)）。"
            operating = false
            onMessage?(message)
            refresh()
            return
        }
        inlinePresenter = nil; inlineRoot = []; inlineEntry = nil
        message = "已执行「\(title)」。"; lastOperationOutcome = "panelMenuAction"
        operationStage = "panel-completed"
        operating = false
        holdMessage = false
        closePanel?()
        refresh()
    }
    func dismissInlineMenu() {
        guard inlinePresenter != nil || inlineEntry != nil else { return }
        let presenter = inlinePresenter
        inlinePresenter = nil; inlineRoot = []; inlineEntry = nil
        presenter?.cancel()
        holdMessage = false
        message = "已关闭菜单。"; operating = false; operationStage = "panel-menu"
        transaction.finish()
        refresh()
    }
    func panelDidClose() {
        inlineDebugLog("panelDidClose presenter=\(inlinePresenter != nil) entry=\(inlineEntry != nil) operating=\(operating)")
        holdMessage = false
        directFailureUntil = .distantPast
        unavailableCache.removeAll()
        if inlinePresenter != nil || inlineEntry != nil { dismissInlineMenu() }
    }
    var isMenuOpen: Bool { inlinePresenter != nil || inlineEntry != nil || preparingInline || Date() < directFailureUntil }
    private func sourceTerminated(_ pid:pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier:pid) else { return true }
        return app.isTerminated
    }
    private func popoverWindows(_ entry:MenuBarEntry) -> Set<UInt32> {
        var result = Set<UInt32>()
        for info in system.windowInfo(onScreenOnly:true) {
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == entry.ownerPID,
                  (info[kCGWindowLayer as String] as? Int ?? 0) > 0,
                  let rect = windowBounds(info), isOnScreen(rect) else { continue }
            result.insert(id)
        }
        return result
    }
    private func windowBounds(_ info:[String:Any]) -> CGRect? {
        guard let value = info[kCGWindowBounds as String] as? [String:Any] else { return nil }
        return CGRect(dictionaryRepresentation:value as CFDictionary)
    }
    private func isOnScreen(_ rect:CGRect) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let top = primary.frame.maxY
        return NSScreen.screens.contains {
            CGRect(x:$0.frame.minX,y:top-$0.frame.maxY,width:$0.frame.width,height:$0.frame.height).intersects(rect)
        }
    }
    private func failDirect(_ error:Error) {
        // A failed direct activation is not a menu mode: explain it and keep
        // the panel usable. Pin the text so the 3-second refresh cannot replace
        // it with the generic "已收纳 N 个图标" status.
        holdMessage = true
        directFailureUntil = Date().addingTimeInterval(3)
        operationStage = "panel-unavailable"
        message = "\(error.localizedDescription) 可点击「展开菜单栏」后手动操作。"
        onMessage?(message)
    }
    private func isReachable(_ rect: CGRect) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let top = primary.frame.maxY
        let appRect = CGRect(x:rect.minX,y:top-rect.maxY,width:rect.width,height:rect.height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appRect) }) else { return false }
        if let safeRight = screen.auxiliaryTopRightArea { return MenuWindowResolver.isInsideVisibleMenuRegion(appRect,region:safeRight) }
        return screen.frame.contains(appRect)
    }
    func stop() {
        timer?.invalidate(); operation?.cancel(); ownershipTask?.cancel(); showAll()
        layout.cancel(); clearInlineCaches()
        NSStatusBar.system.removeStatusItem(divider)
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
