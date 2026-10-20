import AppKit
import SwiftUI
import FlowmoriCore

@MainActor final class CollectionPanelController {
    private let panel: KeyPanel
    private let manager: MenuBarManager
    private var outside: Any?
    private var local: Any?
    private let statusItem: NSStatusItem
    var onSettings: (() -> Void)?
    init(manager:MenuBarManager,settings:Settings,statusItem:NSStatusItem) {
        self.manager = manager; self.statusItem = statusItem
        panel = KeyPanel(contentRect:NSRect(x:0,y:0,width:430,height:340),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.level = .popUpMenu; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace,.fullScreenAuxiliary]; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView:CollectionView(manager:manager,settings:settings,iconService:manager.iconService,onSettings:{ [weak self] in self?.close(); self?.onSettings?() }))
        manager.closePanel = { [weak self] in self?.close() }
    }
    func toggle() {
        if panel.isVisible { close(); return }
        manager.refresh()
        guard let screen = statusItem.button?.window?.screen ?? NSScreen.main else { return }
        let anchor = statusItem.button?.window?.frame ?? NSRect(x:screen.visibleFrame.maxX,y:screen.visibleFrame.maxY,width:20,height:24)
        let target = CGRect(x:anchor.maxX-panel.frame.width,y:screen.visibleFrame.maxY-panel.frame.height-8,width:panel.frame.width,height:panel.frame.height)
        panel.setFrame(ScreenGeometry.clamped(target,to:screen.visibleFrame.insetBy(dx:8,dy:8)),display:false)
        panel.makeKeyAndOrderFront(nil)
        outside = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
        local = NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown,.rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.close(); return nil }
            if event.type != .keyDown && event.window != self.panel && event.window != self.statusItem.button?.window { self.close() }
            return event
        }
    }
    func close() {
        panel.orderOut(nil)
        if let outside { NSEvent.removeMonitor(outside); self.outside = nil }
        if let local { NSEvent.removeMonitor(local); self.local = nil }
    }
}
struct CollectionView: View {
    @ObservedObject var manager: MenuBarManager
    @ObservedObject var settings: Settings
    @ObservedObject var iconService: MenuIconService
    var onSettings: () -> Void
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Label("菜单栏收纳",systemImage:"menubar.rectangle").font(.headline)
                Spacer()
                Button(action:onSettings) { Image(systemName:"gearshape") }.buttonStyle(.plain).help("设置")
            }.padding(16)
            Divider()
            if !settings.menuEnabled {
                ContentUnavailableView { Label("把不常用的图标收起来",systemImage:"tray") } description: { Text("收纳面板在刘海下方展开，让每个图标都能访问。") } actions: { Button("收纳全部") { manager.collectAll() }.disabled(manager.operating || !manager.supported) }
            } else if manager.items.isEmpty {
                ContentUnavailableView { Label("收纳区为空",systemImage:"tray") } description: { Text(manager.message) } actions: { Button("收纳全部") { manager.collectAll() }.disabled(manager.operating || !manager.supported) }
            } else {
                ScrollView {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:88),spacing:10)],spacing:10) {
                        ForEach(manager.items) { item in
                            Button { manager.activate(item,right:false) } label: {
                                VStack(spacing:8) {
                                    if let icon = iconService.icons[item.id] ?? item.icon { Image(nsImage:icon).resizable().scaledToFit().frame(width:30,height:30) }
                                    else { Image(systemName:"app.dashed").frame(width:30,height:30) }
                                    Text(item.name).font(.caption).lineLimit(1)
                                    if item.title != item.name && !item.title.isEmpty { Text(item.title).font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1) }
                                }.frame(maxWidth:.infinity,minHeight:72).padding(5).background(.quaternary.opacity(0.5),in:RoundedRectangle(cornerRadius:10))
                            }.buttonStyle(.plain)
                                .help("直接在收纳盒内打开；不能直接操作时请使用「展开菜单栏」。")
                                .accessibilityLabel("直接打开 \(item.title.isEmpty ? item.name : item.title)")
                                .disabled(!item.ownershipResolved || item.protected || manager.operating)
                                .contextMenu {
                                    Button("打开") { manager.activate(item,right:false) }
                                    Button("右键操作") { manager.activate(item,right:true) }
                                        .disabled(!item.rightDirectAvailable)
                                    Divider()
                                    Button("展开菜单栏") { manager.expandMenuBar() }
                                }
                        }
                    }.padding(12)
                }
            }
            Divider()
            HStack {
                Text(manager.message).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if settings.menuEnabled {
                    Button("展开菜单栏") { manager.expandMenuBar() }
                        .controlSize(.small)
                        .disabled(manager.operating)
                        .help("直接打开不支持的图标时，用此出口到菜单栏手动操作")
                    Button(manager.expanded ? "收纳全部" : "展开") { manager.toggleExpanded() }
                        .controlSize(.small)
                        .disabled(manager.operating)
                }
            }.padding(12)
        }.frame(width:430,height:340)
            .background(.regularMaterial,in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(.primary.opacity(0.12),lineWidth:1))
    }
}
