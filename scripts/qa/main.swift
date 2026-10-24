import AppKit
import ApplicationServices

// Local UI acceptance harness. Never included in Flowmori.app or enabled on login.
// Its only UI targets are Flowmori and this dedicated fixture application.
let fixtureID = "app.flowmori.MenuBarFixture2"
let allowedBundles = ["ai.flowmori.Flowmori", fixtureID]
func emit(_ value: Any) {
    if let data = try? JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys,.fragmentsAllowed]) {
        print(String(decoding:data,as:UTF8.self))
    }
}
func attribute(_ element: AXUIElement,_ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success ? value : nil
}
func children(_ element:AXUIElement) -> [AXUIElement] {
    attribute(element,kAXChildrenAttribute) as? [AXUIElement] ?? []
}
func frame(_ element:AXUIElement) -> CGRect? {
    guard let p = attribute(element,kAXPositionAttribute), let s = attribute(element,kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(p,to:AXValue.self),.cgPoint,&point),
          AXValueGetValue(unsafeBitCast(s,to:AXValue.self),.cgSize,&size) else { return nil }
    return CGRect(origin:point,size:size)
}
func tree(_ element:AXUIElement,_ path:[Int] = [],_ depth:Int = 0,_ ancestors:[AXUIElement] = []) -> [String:Any] {
    guard !ancestors.contains(where: { CFEqual($0,element) }) else { return ["path":path,"cycle":true] }
    var value: [String:Any] = ["path":path]
    for key in [kAXRoleAttribute,kAXTitleAttribute,kAXDescriptionAttribute,kAXIdentifierAttribute,kAXValueAttribute,kAXEnabledAttribute] {
        if let data = attribute(element,key), data is NSString || data is NSNumber { value[key] = data }
    }
    if let f = frame(element) { value["frame"] = [f.minX,f.minY,f.width,f.height] }
    var actions: CFArray?
    if AXUIElementCopyActionNames(element,&actions) == .success { value["actions"] = actions }
    let isSystemMenu = value[kAXRoleAttribute] as? String == kAXMenuBarItemRole && value[kAXTitleAttribute] as? String == "Apple"
    if depth < 12 && !isSystemMenu { value["children"] = children(element).prefix(150).enumerated().map { tree($0.element,path+[$0.offset],depth+1,ancestors+[element]) } }
    return value
}
func findAX(_ element:AXUIElement,_ role:String,_ text:String,_ depth:Int = 0,_ ancestors:[AXUIElement] = []) -> AXUIElement? {
    guard depth <= 12, !ancestors.contains(where: { CFEqual($0,element) }) else { return nil }
    let candidates = [attribute(element,kAXDescriptionAttribute) as? String,
                      attribute(element,kAXTitleAttribute) as? String].compactMap { $0 }
    if (attribute(element,kAXRoleAttribute) as? String) == role,
       candidates.contains(where: { $0.contains(text) }),
       let value = frame(element), value.width > 0 { return element }
    for child in children(element) {
        if let found = findAX(child,role,text,depth+1,ancestors+[element]) { return found }
    }
    return nil
}
func axState(_ root:AXUIElement) -> [String:Any] {
    var menus:[String] = [], items:[String] = [], windows:[[Double]] = []
    var popover = false
    func walk(_ element:AXUIElement,_ depth:Int,_ ancestors:[AXUIElement]) {
        guard depth <= 14, !ancestors.contains(where: { CFEqual($0,element) }) else { return }
        let role = attribute(element,kAXRoleAttribute) as? String ?? ""
        let title = attribute(element,kAXTitleAttribute) as? String ?? ""
        let desc = attribute(element,kAXDescriptionAttribute) as? String ?? ""
        let value = attribute(element,kAXValueAttribute) as? String ?? ""
        let f = frame(element)
        let visible = (f?.width ?? 0) > 0 && (f?.height ?? 0) > 0
        if role == "AXMenu", visible { menus.append(title) }
        if role == "AXMenuItem", visible { items.append(title) }
        if visible && (desc.contains("关闭测试弹窗") || value.contains("Flowmori 专用测试弹窗")) { popover = true }
        if role == "AXWindow", visible, let f { windows.append([f.minX,f.minY,f.width,f.height]) }
        for child in children(element) { walk(child,depth+1,ancestors+[element]) }
    }
    walk(root,0,[])
    return ["menus":menus,"menuItems":items,"popover":popover,"windows":windows]
}

final class DropProbeView: NSView {
    var onEvent: ((String,[String:Any]) -> Void)?
    override init(frame:NSRect) {
        super.init(frame:frame)
        registerForDraggedTypes([.fileURL,.URL,.string,.tiff,.png,.pdf,.html,.rtf,.color,.multipleTextSelection,
                                 NSPasteboard.PasteboardType("public.data"),NSPasteboard.PasteboardType("com.apple.finder.node"),
                                 NSPasteboard.PasteboardType("NSFilenamesPboardType")])
    }
    required init?(coder:NSCoder) { fatalError() }
    private func describe(_ sender:NSDraggingInfo) -> [String:Any] {
        let pasteboard = sender.draggingPasteboard
        return ["types":pasteboard.types?.map(\.rawValue) ?? [],
                "source":String(describing:sender.draggingSource),
                "location":[sender.draggingLocation.x,sender.draggingLocation.y]]
    }
    override func draggingEntered(_ sender:NSDraggingInfo) -> NSDragOperation {
        onEvent?("drag-entered",describe(sender)); return .copy
    }
    override func draggingUpdated(_ sender:NSDraggingInfo) -> NSDragOperation {
        onEvent?("drag-updated",describe(sender)); return .copy
    }
    override func prepareForDragOperation(_ sender:NSDraggingInfo) -> Bool {
        onEvent?("drag-prepare",describe(sender)); return true
    }
    override func performDragOperation(_ sender:NSDraggingInfo) -> Bool {
        onEvent?("drag-perform",describe(sender)); return true
    }
    override func draggingExited(_ sender:NSDraggingInfo?) {
        onEvent?("drag-exited",sender.map(describe) ?? [:])
    }
    override func concludeDragOperation(_ sender:NSDraggingInfo?) {
        onEvent?("drag-concluded",sender.map(describe) ?? [:])
    }
}

final class Fixture: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    var items: [NSStatusItem] = []
    var popover = NSPopover()
    var document: NSWindow!
    var textView: NSTextView!
    var dropWindow: NSWindow?
    let log: URL
    let dragProbe: Bool
    init(log:URL,dragProbe:Bool = false) { self.log = log; self.dragProbe = dragProbe }
    func record(_ event:String,_ details:[String:Any] = [:]) {
        var record: [String:Any] = ["event":event,"time":Date().timeIntervalSince1970,"pid":getpid()]
        for (key,value) in details { record[key] = value }
        guard var data = try? JSONSerialization.data(withJSONObject:record,options:.sortedKeys) else { return }
        data.append(10)
        if !FileManager.default.fileExists(atPath:log.path) { FileManager.default.createFile(atPath:log.path,contents:nil) }
        if let file = try? FileHandle(forWritingTo:log) { defer { try? file.close() }; _ = try? file.seekToEnd(); try? file.write(contentsOf:data) }
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        for (index,name) in ["Normal","Popover","Right"].enumerated() {
            let item = NSStatusBar.system.statusItem(withLength:[36,48,24][index])
            item.autosaveName = "Flowmori.QA.2.\(name)"
            item.button?.title = "F\(index+1)"; item.button?.toolTip = "Flowmori QA \(name)"
            item.button?.setAccessibilityLabel("Flowmori QA \(name)")
            item.button?.target = self; item.button?.action = #selector(clicked(_:))
            item.button?.sendAction(on:[.leftMouseUp,.rightMouseUp]); items.append(item)
        }
        let appMenu = NSMenu(); let root = NSMenuItem(); appMenu.addItem(root)
        let menu = NSMenu(); root.submenu = menu
        let quit = NSMenuItem(title:"退出测试程序",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"); menu.addItem(quit)
        let editRoot = NSMenuItem(title:"编辑",action:nil,keyEquivalent:""); appMenu.addItem(editRoot)
        let edit = NSMenu(title:"编辑"); editRoot.submenu = edit
        for (title,selector,key) in [("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] {
            edit.addItem(NSMenuItem(title:title,action:selector,keyEquivalent:key))
        }
        NSApp.mainMenu = appMenu
        document = NSWindow(contentRect:NSRect(x:180,y:250,width:640,height:420),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        document.title = "Flowmori 专用验收文档"; document.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame:document.contentView!.bounds); scroll.autoresizingMask = [.width,.height]; scroll.hasVerticalScroller = true
        textView = NSTextView(frame:scroll.bounds); textView.autoresizingMask = [.width,.height]; textView.isRichText = true
        textView.textContainerInset = NSSize(width:24,height:24)
        let content = NSMutableAttributedString(string:"Flowmori 验收：中文复制与截图取消。\n第二行：富文本 Bold 与链接 https://example.com\n截图区域：ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789",attributes:[.font:NSFont.systemFont(ofSize:22),.foregroundColor:NSColor.labelColor])
        content.addAttributes([.font:NSFont.boldSystemFont(ofSize:22),.foregroundColor:NSColor.systemBlue],range:(content.string as NSString).range(of:"Bold"))
        textView.textStorage?.setAttributedString(content); scroll.documentView = textView; document.contentView = scroll
        document.makeKeyAndOrderFront(nil); document.makeFirstResponder(textView)
        if dragProbe {
            let window = NSWindow(contentRect:NSRect(x:300,y:210,width:520,height:320),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title = "Flowmori 拖放探针"; window.isReleasedWhenClosed = false
            let view = DropProbeView(frame:window.contentView!.bounds); view.autoresizingMask = [.width,.height]
            view.onEvent = { [weak self] event, details in self?.record(event,details) }
            window.contentView = view; window.makeKeyAndOrderFront(nil); dropWindow = window
        }
        NSApp.activate(ignoringOtherApps:true)
        record("launched",["dragProbe":dragProbe])
    }
    @objc func clicked(_ sender:NSStatusBarButton) {
        guard let index = items.firstIndex(where: { $0.button === sender }) else { return }
        let right = NSApp.currentEvent?.type == .rightMouseUp
        record("icon\(index+1)-\(right ? "right" : "left")")
        if index == 1 && !right {
            let view = NSViewController(); view.view = NSView(frame:NSRect(x:0,y:0,width:260,height:150))
            let label = NSTextField(labelWithString:"Flowmori 专用测试弹窗"); label.frame = NSRect(x:20,y:112,width:220,height:30); view.view.addSubview(label)
            let close = NSButton(title:"关闭测试弹窗",target:self,action:#selector(closePopover)); close.frame = NSRect(x:45,y:68,width:170,height:30); view.view.addSubview(close)
            let quit = NSButton(title:"退出测试程序",target:self,action:#selector(quitFixture)); quit.frame = NSRect(x:45,y:28,width:170,height:30); view.view.addSubview(quit)
            popover.contentViewController = view
            popover.behavior = CommandLine.arguments.contains("--persistent-popover") ? .applicationDefined : .transient
            popover.delegate = self
            popover.show(relativeTo:sender.bounds,of:sender,preferredEdge:.minY)
        } else {
            let menu = NSMenu(title:right ? "QA-Right" : "QA-Normal"); menu.delegate = self
            let item = NSMenuItem(title:right ? "右键测试操作" : "普通菜单测试操作",action:#selector(testAction),keyEquivalent:""); item.target = self
            menu.addItem(item); menu.addItem(.separator()); menu.addItem(withTitle:"仅供 Flowmori 验收",action:nil,keyEquivalent:"")
            let quit = NSMenuItem(title:"退出测试程序",action:#selector(self.quitFixture),keyEquivalent:""); quit.target = self; menu.addItem(quit)
            menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.minY),in:sender)
        }
    }
    @objc func closePopover() { popover.performClose(nil) }
    @objc func testAction() { record("menu-action") }
    @objc func quitFixture() { record("quit-from-menu"); NSApp.terminate(nil) }
    func menuWillOpen(_ menu:NSMenu) { record("\(menu.title)-opened") }
    func menuDidClose(_ menu:NSMenu) { record("\(menu.title)-closed") }
    func popoverDidShow(_ notification:Notification) { record("popover-opened") }
    func popoverDidClose(_ notification:Notification) { record("popover-closed") }
    func applicationWillTerminate(_ notification:Notification) { record("terminated") }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool {
        document.makeKeyAndOrderFront(nil); document.makeFirstResponder(textView); return true
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--fixture" {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let fixtureLog = args.count > 1 && !args[1].hasPrefix("--") ? args[1] : "/tmp/flowmori-qa-events.jsonl"
    let fixture = Fixture(log:URL(fileURLWithPath:fixtureLog),dragProbe:args.contains("--drag-probe"))
    app.delegate = fixture; app.run()
} else {
    do {
        guard let path = args.first else { throw NSError(domain:"QA",code:1,userInfo:[NSLocalizedDescriptionKey:"Pass a JSON request file or --fixture log-path"]) }
        let request = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path))) as! [String:Any]
        let operation = request["op"] as? String ?? "status"
        if operation == "status" {
            emit(["accessibility":AXIsProcessTrusted(),"screenCapture":CGPreflightScreenCaptureAccess(),"front":NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""])
        } else {
            guard AXIsProcessTrusted() else { throw NSError(domain:"QA",code:2,userInfo:[NSLocalizedDescriptionKey:"The script host needs Accessibility permission"]) }
            let inputs = ["activate","menuDrag","menuMoveBefore","menuClick","dragNative","press","pressDescription","probeDirect","set","key","typeText","doubleClick","click","drag"]
            if inputs.contains(operation), NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow" {
                throw NSError(domain:"QA",code:9,userInfo:[NSLocalizedDescriptionKey:"The desktop is locked; no test input was sent"])
            }
            let bundle = request["bundle"] as? String ?? fixtureID
            guard allowedBundles.contains(bundle), let target = NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first else { throw NSError(domain:"QA",code:3,userInfo:[NSLocalizedDescriptionKey:"Target is not a running allowed test application"]) }
            let root = AXUIElementCreateApplication(target.processIdentifier)
            AXUIElementSetMessagingTimeout(root,2)
            switch operation {
            case "activate": target.activate(options:[.activateAllWindows]); emit(["ok":true])
            case "menuProbe", "menuDrag", "menuMoveBefore", "menuClick":
                Task { @MainActor in
                    var placementTrace: [[String:Any]] = []
                    do {
                        let system = MenuBarSystem()
                        system.placementObserver = { source, neighbor in
                            placementTrace.append(["source":source.map(NSStringFromRect) ?? "missing", "neighbor":neighbor.map(NSStringFromRect) ?? "missing"])
                        }
                        await system.refreshOwnership()
                        let entries = try system.entries()
                        let scoped = entries.filter { allowedBundles.contains($0.bundleID) }
                        if operation != "menuProbe" {
                            guard let id = request["id"] as? UInt32, let entry = scoped.first(where: { $0.id == id }), entry.bundleID == fixtureID else {
                                throw NSError(domain:"QA",code:8,userInfo:[NSLocalizedDescriptionKey:"Only fixture icons can be moved or clicked by the bridge test"])
                            }
                            if operation == "menuMoveBefore" {
                                guard let neighbor = request["neighbor"] as? UInt32,
                                      scoped.contains(where: { $0.id == neighbor }) else { throw NSError(domain:"QA",code:8) }
                                try await system.drag(entry,before:neighbor)
                            } else if operation == "menuDrag" {
                                guard let point = request["point"] as? [Double], point.count == 2 else { throw NSError(domain:"QA",code:6) }
                                try await system.drag(entry,to:CGPoint(x:point[0],y:point[1]))
                            } else { try await system.click(entry,right:request["right"] as? Bool ?? false) }
                            try await Task.sleep(for:.milliseconds(400))
                        }
                        emit(["placementTrace":placementTrace,"layout":entries.map { ["id":$0.id,"protected":$0.protected,"resolved":$0.ownershipResolved,"frame":[Double($0.frame.minX),Double($0.frame.minY),Double($0.frame.width),Double($0.frame.height)]] as [String:Any] },
                        "unresolved":entries.filter { !$0.ownershipResolved }.count,
                        "nonSystemDropRegions":entries.filter { $0.ownershipResolved && !$0.protected && $0.frame.minX >= 950 }.map { ["id":$0.id,"frame":[Double($0.frame.minX),Double($0.frame.minY),Double($0.frame.width),Double($0.frame.height)]] as [String:Any] },
                        "scoped":try system.entries().filter { allowedBundles.contains($0.bundleID) }.map {
                            ["id":$0.id,"hostPID":$0.pid,"ownerPID":$0.ownerPID,"bundle":$0.bundleID,"title":$0.title,"frame":[Double($0.frame.minX),Double($0.frame.minY),Double($0.frame.width),Double($0.frame.height)]] as [String:Any]
                        }])
                        exit(0)
                    } catch { emit(["error":error.localizedDescription,"placementTrace":placementTrace]); exit(1) }
                }
                RunLoop.main.run()
            case "tree": emit(tree(root))
            case "extras":
                if let value = attribute(root,kAXExtrasMenuBarAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() { emit(tree(unsafeBitCast(value,to:AXUIElement.self))) }
                else { emit(["error":"No AXExtrasMenuBar"]) }
            case "press", "set":
                var element = root
                for index in request["path"] as? [Int] ?? [] {
                    let nested = children(element)
                    guard nested.indices.contains(index) else { throw NSError(domain:"QA",code:4,userInfo:[NSLocalizedDescriptionKey:"Stale accessibility path"]) }; element = nested[index]
                }
                let error = operation == "press" ? AXUIElementPerformAction(element,kAXPressAction as CFString) : AXUIElementSetAttributeValue(element,kAXValueAttribute as CFString,(request["value"] as? String ?? "") as CFString)
                emit(["errorCode":error.rawValue])
            case "pressDescription":
                guard let role = request["role"] as? String, let text = request["text"] as? String, !text.isEmpty else {
                    throw NSError(domain:"QA",code:7,userInfo:[NSLocalizedDescriptionKey:"Missing role or text"])
                }
                func match(_ element:AXUIElement,_ depth:Int) -> AXUIElement? {
                    guard depth <= 12 else { return nil }
                    let candidates = [attribute(element,kAXDescriptionAttribute) as? String,
                                      attribute(element,kAXTitleAttribute) as? String].compactMap { $0 }
                    if (attribute(element,kAXRoleAttribute) as? String) == role,
                       candidates.contains(where: { $0.contains(text) }),
                       let value = frame(element), value.width > 0 { return element }
                    for child in children(element) {
                        if let found = match(child,depth+1) { return found }
                    }
                    return nil
                }
                // Locate and press the live element in one call so a panel refresh
                // cannot make a previously captured accessibility path stale.
                guard let element = match(root,0) else {
                    throw NSError(domain:"QA",code:4,userInfo:[NSLocalizedDescriptionKey:"Missing scoped control: \(text)"])
                }
                let error = AXUIElementPerformAction(element,kAXPressAction as CFString)
                emit(["errorCode":error.rawValue])
            case "dragNative":
                Task { @MainActor in
                    do {
                        let system = MenuBarSystem()
                        await system.refreshOwnership()
                        let entries = try system.entries()
                        guard let id = request["id"] as? UInt32, let entry = entries.first(where: { $0.id == id }), entry.bundleID == fixtureID else {
                            throw NSError(domain:"QA",code:8,userInfo:[NSLocalizedDescriptionKey:"Only fixture icons can be dragged"])
                        }
                        guard let point = request["point"] as? [Double], point.count == 2 else { throw NSError(domain:"QA",code:6) }
                        let command = request["command"] as? Bool ?? false
                        let end = CGPoint(x:point[0],y:point[1])
                        let start = CGPoint(x:entry.frame.midX,y:entry.frame.midY)
                        let source = CGEventSource(stateID:.hidSystemState)
                        func event(_ type:CGEventType,_ location:CGPoint) -> CGEvent? {
                            guard let value = CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:location,mouseButton:.left) else { return nil }
                            value.flags = command ? .maskCommand : []
                            value.setIntegerValueField(.mouseEventWindowUnderMousePointer,value:Int64(entry.id))
                            value.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value:Int64(entry.id))
                            if command, let field = CGEventField(rawValue:0x33) { value.setIntegerValueField(field,value:Int64(entry.id)) }
                            value.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(entry.pid))
                            value.setIntegerValueField(.eventSourceUserData,value:0x464D4F52)
                            value.setIntegerValueField(.mouseEventClickState,value:1)
                            return value
                        }
                        guard let down = event(.leftMouseDown,start), let up = event(.leftMouseUp,end) else { throw NSError(domain:"QA",code:11) }
                        down.post(tap:.cgSessionEventTap); usleep(120_000)
                        for step in 1...16 {
                            let part = CGFloat(step)/16
                            guard let motion = event(.leftMouseDragged,CGPoint(x:start.x+(end.x-start.x)*part,y:start.y+(end.y-start.y)*part)) else { continue }
                            motion.post(tap:.cgSessionEventTap); usleep(35_000)
                        }
                        up.post(tap:.cgSessionEventTap); usleep(800_000)
                        let after = try system.entries()
                        emit(["start":[start.x,start.y],"end":[end.x,end.y],"command":command,
                              "layout":after.map { ["id":$0.id,"bundle":$0.bundleID,"title":$0.title,"frame":[Double($0.frame.minX),Double($0.frame.minY),Double($0.frame.width),Double($0.frame.height)]] as [String:Any] }])
                        exit(0)
                    } catch { emit(["error":error.localizedDescription]); exit(1) }
                }
                RunLoop.main.run()
            case "sampleLayout":
                Task { @MainActor in
                    do {
                        let duration = request["duration"] as? Double ?? 6
                        let interval = request["intervalMs"] as? Int ?? 50
                        let system = MenuBarSystem()
                        await system.refreshOwnership()
                        let baseline = try system.entries().filter { allowedBundles.contains($0.bundleID) }
                        let baseFrames = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id,$0.frame) })
                        let baseIDs = Set(baseFrames.keys)
                        var changes: [[String:Any]] = []
                        var samples = 0
                        let started = Date()
                        while Date().timeIntervalSince(started) < duration {
                            let now = try system.entries().filter { allowedBundles.contains($0.bundleID) }
                            let ids = Set(now.map(\.id))
                            for entry in now where baseIDs.contains(entry.id) {
                                guard let base = baseFrames[entry.id] else { continue }
                                if abs(entry.frame.minX-base.minX) > 0.5 || abs(entry.frame.minY-base.minY) > 0.5 {
                                    changes.append(["t":Date().timeIntervalSince(started),"id":entry.id,
                                                    "x":entry.frame.minX,"y":entry.frame.minY,
                                                    "baseX":base.minX,"baseY":base.minY])
                                }
                            }
                            for missing in baseIDs.subtracting(ids) {
                                changes.append(["t":Date().timeIntervalSince(started),"id":missing,"missing":true])
                            }
                            samples += 1
                            usleep(useconds_t(max(10, interval) * 1000))
                        }
                        emit(["baseline":baseline.map { ["id":$0.id,"title":$0.title,"frame":[Double($0.frame.minX),Double($0.frame.minY),Double($0.frame.width),Double($0.frame.height)]] as [String:Any] },
                              "samples":samples,"duration":Date().timeIntervalSince(started),
                              "changeCount":changes.count,"changes":Array(changes.prefix(100))])
                        exit(0)
                    } catch { emit(["error":error.localizedDescription]); exit(1) }
                }
                RunLoop.main.run()
            case "probeDirect":
                guard bundle == fixtureID, let role = request["role"] as? String, let text = request["text"] as? String, !text.isEmpty else {
                    throw NSError(domain:"QA",code:7,userInfo:[NSLocalizedDescriptionKey:"probeDirect requires fixture bundle, role and text"])
                }
                Task { @MainActor in
                    do {
                        let system = MenuBarSystem()
                        await system.refreshOwnership()
                        let initial = try system.entries()
                        let initialFrames = Dictionary(uniqueKeysWithValues: initial.map { ($0.id,$0.frame) })
                        guard let extrasValue = attribute(root,kAXExtrasMenuBarAttribute), CFGetTypeID(extrasValue) == AXUIElementGetTypeID() else {
                            throw NSError(domain:"QA",code:10,userInfo:[NSLocalizedDescriptionKey:"No AXExtrasMenuBar"])
                        }
                        let extras = unsafeBitCast(extrasValue,to:AXUIElement.self)
                        guard let axTarget = findAX(extras,role,text) else {
                            throw NSError(domain:"QA",code:4,userInfo:[NSLocalizedDescriptionKey:"Missing collapsed extras item: \(text)"])
                        }
                        var actionValue: CFArray?
                        let actionError = AXUIElementCopyActionNames(axTarget,&actionValue)
                        let actionNames = actionValue as? [String] ?? []
                        let actionName = request["action"] as? String ?? (kAXPressAction as String)
                        var samples: [[String:Any]] = [], changes: [[String:Any]] = []
                        let started = Date()
                        func sample(_ phase:String,_ time:Double) {
                            guard let entries = try? system.entries() else { return }
                            samples.append(["t":time,"phase":phase,
                                            "items":entries.filter { allowedBundles.contains($0.bundleID) }.map { ["id":$0.id,"x":$0.frame.minX] }])
                            for entry in entries {
                                guard let base = initialFrames[entry.id], abs(entry.frame.minX-base.minX) > 0.5, changes.count < 80 else { continue }
                                changes.append(["t":time,"phase":phase,"id":entry.id,"x":entry.frame.minX,"base":base.minX])
                            }
                        }
                        sample("before",0)
                        let pressError = AXUIElementPerformAction(axTarget,actionName as CFString)
                        for _ in 1...60 { usleep(50_000); sample("during",Date().timeIntervalSince(started)) }
                        let during = axState(root)
                        let visibleDuring = Array(system.visibleWindows(pid:target.processIdentifier))
                        let windowInfo = system.windowInfo(onScreenOnly:true)
                        let visibleDetails = windowInfo.compactMap { value -> [String:Any]? in
                            guard let id = value[kCGWindowNumber as String] as? UInt32, visibleDuring.contains(id) else { return nil }
                            var details: [String:Any] = ["id":id]
                            if let bounds = value[kCGWindowBounds as String] { details["bounds"] = bounds }
                            if let layer = value[kCGWindowLayer as String] { details["layer"] = layer }
                            if let name = value[kCGWindowName as String] { details["name"] = name }
                            return details
                        }
                        let menuOpen = !((during["menuItems"] as? [String]) ?? []).isEmpty || !((during["menus"] as? [String]) ?? []).isEmpty
                        let popoverOpen = during["popover"] as? Bool ?? false
                        func escape() {
                            let source = CGEventSource(stateID:.hidSystemState)
                            for down in [true,false] {
                                CGEvent(keyboardEventSource:source,virtualKey:53,keyDown:down)?.post(tap:.cghidEventTap)
                                usleep(70_000)
                            }
                        }
                        if menuOpen {
                            target.activate(options:[])
                            usleep(120_000)
                            escape()
                        } else if popoverOpen {
                            if let close = findAX(root,"AXButton","关闭测试弹窗") {
                                _ = AXUIElementPerformAction(close,kAXPressAction as CFString)
                            } else {
                                target.activate(options:[]); usleep(120_000); escape()
                            }
                        }
                        usleep(600_000)
                        let after = axState(root)
                        sample("after",Date().timeIntervalSince(started))
                        emit(["target":text,"role":role,"action":actionName,"actions":actionNames,"actionError":actionError.rawValue,
                              "pressError":pressError.rawValue,"during":during,"after":after,
                              "visibleDuring":visibleDuring.map { Int($0) },"visibleDetails":visibleDetails,
                              "sampledSeconds":Date().timeIntervalSince(started),
                              "changeCount":changes.count,"changes":changes,"samples":samples])
                        exit(0)
                    } catch { emit(["error":error.localizedDescription]); exit(1) }
                }
                RunLoop.main.run()
            case "typeText":
                guard allowedBundles.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") else { throw NSError(domain:"QA",code:5,userInfo:[NSLocalizedDescriptionKey:"Focus is outside allowed test apps"]) }
                let text = request["text"] as? String ?? ""
                guard !text.isEmpty else { throw NSError(domain:"QA",code:7,userInfo:[NSLocalizedDescriptionKey:"Missing text"]) }
                let source = CGEventSource(stateID:.hidSystemState)
                let units = Array(text.utf16)
                var index = 0
                while index < units.count {
                    let chunk = Array(units[index..<min(units.count, index+16)])
                    let down = CGEvent(keyboardEventSource:source,virtualKey:0,keyDown:true)!
                    chunk.withUnsafeBufferPointer { buffer in
                        if let base = buffer.baseAddress { down.keyboardSetUnicodeString(stringLength: buffer.count,unicodeString: base) }
                    }
                    down.post(tap:.cghidEventTap); usleep(30_000)
                    let up = CGEvent(keyboardEventSource:source,virtualKey:0,keyDown:false)!
                    up.post(tap:.cghidEventTap); usleep(30_000)
                    index += chunk.count
                }
                emit(["ok":true,"characters":units.count])
            case "key":
                guard allowedBundles.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") else { throw NSError(domain:"QA",code:5,userInfo:[NSLocalizedDescriptionKey:"Focus is outside allowed test apps"]) }
                let key = CGKeyCode(request["keyCode"] as? Int ?? 53), flags = CGEventFlags(rawValue:request["flags"] as? UInt64 ?? 0)
                let source = CGEventSource(stateID:.hidSystemState)
                for down in [true,false] { let event = CGEvent(keyboardEventSource:source,virtualKey:key,keyDown:down)!; event.flags = flags; event.post(tap:.cghidEventTap); usleep(70_000) }
                emit(["ok":true])
            case "doubleClick":
                guard allowedBundles.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") else { throw NSError(domain:"QA",code:5,userInfo:[NSLocalizedDescriptionKey:"Focus is outside allowed test apps"]) }
                guard let point = request["point"] as? [Double], point.count == 2 else { throw NSError(domain:"QA",code:6) }
                let location = CGPoint(x:point[0],y:point[1])
                let source = CGEventSource(stateID:.hidSystemState)
                func send(_ type:CGEventType,_ state:Int64) {
                    let event = CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:location,mouseButton:.left)!
                    event.setIntegerValueField(.mouseEventClickState,value:state); event.post(tap:.cghidEventTap)
                }
                send(.mouseMoved,1); usleep(80_000)
                send(.leftMouseDown,1); usleep(30_000); send(.leftMouseUp,1); usleep(90_000)
                send(.leftMouseDown,2); usleep(30_000); send(.leftMouseUp,2)
                emit(["ok":true])
            case "click", "drag":
                guard let point = request["point"] as? [Double], point.count == 2 else { throw NSError(domain:"QA",code:6) }
                // Points must come from a preceding snapshot of the scoped test UI.
                let start = CGPoint(x:point[0],y:point[1]); let endArray = request["end"] as? [Double] ?? point
                guard endArray.count == 2 else { throw NSError(domain:"QA",code:6) }
                let end = CGPoint(x:endArray[0],y:endArray[1]), right = request["right"] as? Bool ?? false
                let flags = CGEventFlags(rawValue:request["flags"] as? UInt64 ?? 0), source = CGEventSource(stateID:.hidSystemState)
                func send(_ type:CGEventType,_ location:CGPoint) { let event = CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:location,mouseButton:right ? .right : .left)!; event.flags = flags; event.setIntegerValueField(.mouseEventClickState,value:1); event.post(tap:.cghidEventTap) }
                send(.mouseMoved,start); usleep(120_000); send(right ? .rightMouseDown : .leftMouseDown,start); usleep(150_000)
                if operation == "drag" {
                    for step in 1...12 { let part = CGFloat(step)/12; send(.leftMouseDragged,CGPoint(x:start.x+(end.x-start.x)*part,y:start.y+(end.y-start.y)*part)); usleep(25_000) }
                }
                send(right ? .rightMouseUp : .leftMouseUp,end); emit(["ok":true])
            default: throw NSError(domain:"QA",code:7,userInfo:[NSLocalizedDescriptionKey:"Unknown operation"])
            }
        }
    } catch { emit(["error":error.localizedDescription]); exit(1) }
}
