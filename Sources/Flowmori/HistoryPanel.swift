import AppKit
import SwiftUI
import ImageIO
import FlowmoriCore

@MainActor final class HistorySelection: ObservableObject {
    @Published var query = ""
    @Published var favoritesOnly = false
    @Published var selectedID: String?
    let service: ClipboardService
    init(service:ClipboardService) { self.service = service }
    var filtered: [ClipRecord] {
        service.records.filter { record in
            (!favoritesOnly || record.favorite) && (query.isEmpty || record.text.localizedStandardContains(query) || record.sourceName.localizedStandardContains(query) || (record.kind == .image && "图片 截图".localizedStandardContains(query)))
        }
    }
    var selected: ClipRecord? { filtered.first(where: { $0.id == selectedID }) ?? filtered.first }
    func move(_ offset:Int) {
        let records = filtered
        guard !records.isEmpty else { return }
        let current = records.firstIndex(where: { $0.id == selectedID }) ?? (offset > 0 ? -1 : records.count)
        selectedID = records[min(max(current+offset,0),records.count-1)].id
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class HistoryPanelController {
    let panel: KeyPanel
    let selection: HistorySelection
    private let service: ClipboardService
    private var previousApplication: NSRunningApplication?
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    var onPin: ((NSImage) -> Void)?
    var onSettings: (() -> Void)?
    init(service:ClipboardService,settings:Settings) {
        self.service = service; selection = HistorySelection(service:service)
        panel = KeyPanel(contentRect:NSRect(x:0,y:0,width:410,height:540),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace,.fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView:HistoryView(service:service,settings:settings,selection:selection,
            onCopy:{ [weak self] record in self?.copy(record) },
            onPin:{ [weak self] record in self?.pin(record) },
            onSettings:{ [weak self] in self?.close(restore:false); self?.onSettings?() }))
        resignObserver = NotificationCenter.default.addObserver(forName:NSWindow.didResignKeyNotification,object:panel,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(restore:false) }
        }
    }
    func toggle() {
        if panel.isVisible { close(restore:true); return }
        previousApplication = NSWorkspace.shared.frontmostApplication
        selection.query = ""; selection.selectedID = selection.filtered.first?.id
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let proposed = NSRect(x:point.x+10,y:point.y-panel.frame.height-10,width:panel.frame.width,height:panel.frame.height)
        panel.setFrame(ScreenGeometry.clamped(proposed,to:screen.visibleFrame.insetBy(dx:8,dy:8)),display:false)
        // A nonactivating panel can take keyboard focus over another app's
        // full-screen Space without switching to our settings window's Space.
        panel.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            // Let the input method use Return/arrows to choose Chinese candidates.
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            switch event.keyCode {
            case 53: self.close(restore:true); return nil
            case 125: self.selection.move(1); return nil
            case 126: self.selection.move(-1); return nil
            case 36,76: if let selected = self.selection.selected { self.copy(selected) }; return nil
            default: return event
            }
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(restore:false) }
        }
    }
    func close(restore:Bool) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        panel.orderOut(nil)
        if restore, let app = previousApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !app.isTerminated { app.activate(options:[]) }
    }
    private func copy(_ record:ClipRecord) { service.copy(record) { [weak self] success in if success { self?.close(restore:true) } } }
    private func pin(_ record:ClipRecord) {
        guard let url = service.imageURL(record), let image = NSImage(contentsOf:url) else { return }
        close(restore:true); onPin?(image)
    }
}

struct HistoryView: View {
    @ObservedObject var service: ClipboardService
    @ObservedObject var settings: Settings
    @ObservedObject var selection: HistorySelection
    var onCopy: (ClipRecord) -> Void
    var onPin: (ClipRecord) -> Void
    var onSettings: () -> Void
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Image(systemName:"clipboard").foregroundStyle(.tint)
                Text("剪贴板").font(.headline)
                Spacer()
                Button { settings.paused.toggle() } label: { Image(systemName:settings.paused ? "play.fill" : "pause.fill") }
                    .help(settings.paused ? "继续记录" : "暂停记录")
                Button(action:onSettings) { Image(systemName:"gearshape") }.help("设置")
            }.buttonStyle(.plain).padding(16)
            HStack(spacing:8) {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索文字或来源应用",text:$selection.query).textFieldStyle(.plain).focused($searchFocused)
                if !selection.query.isEmpty { Button { selection.query = "" } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain) }
            }.padding(10).background(.quaternary,in:RoundedRectangle(cornerRadius:9)).padding(.horizontal,12)
            HStack {
                Picker("筛选",selection:$selection.favoritesOnly) { Text("全部").tag(false); Text("收藏").tag(true) }.pickerStyle(.segmented).frame(width:145)
                Spacer()
                Text("\(selection.filtered.count) 条").font(.caption).foregroundStyle(.secondary)
            }.padding(12)
            Divider()
            if service.needsPermission {
                ContentUnavailableView { Label("允许读取剪贴板",systemImage:"hand.raised") } description: { Text("开启后，Flowmori 会在本机保存你复制的内容。") } actions: { Button("允许读取") { service.requestRead() } }
            } else if selection.filtered.isEmpty {
                ContentUnavailableView(selection.query.isEmpty ? "还没有记录" : "没有匹配的内容",systemImage:"clipboard",description:Text(selection.query.isEmpty ? "复制文字或图片后，会显示在这里。" : "试试其他关键词。"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing:5) {
                            ForEach(selection.filtered) { record in
                                row(record).id(record.id)
                            }
                        }.padding(8)
                    }.onChange(of:selection.selectedID) { _,id in if let id { proxy.scrollTo(id,anchor:.center) } }
                }
            }
            Divider()
            HStack {
                Text(settings.paused ? "已暂停记录" : "↑↓ 选择   ↩ 复制   Esc 关闭")
                Spacer(); Text("Flowmori").fontWeight(.medium)
            }.font(.caption2).foregroundStyle(.secondary).padding(12)
        }
        .frame(width:410,height:540).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14))
        .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(.primary.opacity(0.12),lineWidth:1))
        .onAppear { searchFocused = true }
        .onChange(of:selection.query) { _,_ in selection.selectedID = selection.filtered.first?.id }
        .onChange(of:selection.favoritesOnly) { _,_ in selection.selectedID = selection.filtered.first?.id }
    }
    private func row(_ record:ClipRecord) -> some View {
        HStack(spacing:12) {
            if let url = service.imageURL(record) { ThumbnailView(url:url).frame(width:62,height:52).clipped().clipShape(RoundedRectangle(cornerRadius:5)) }
            else { Image(systemName:record.text.hasPrefix("http") ? "link" : "text.alignleft").font(.title3).foregroundStyle(.secondary).frame(width:28) }
            VStack(alignment:.leading,spacing:5) {
                if record.kind == .image { Text("图片").font(.system(size:13,weight:.medium)) }
                else { Text(record.text).font(.system(size:13)).lineLimit(3).multilineTextAlignment(.leading) }
                HStack(spacing:5) {
                    Text(record.sourceName.isEmpty ? "未知来源" : record.sourceName).lineLimit(1)
                    Text("·")
                    // A static timestamp avoids per-second SwiftUI layout work
                    // for every history row while the panel is ordered out.
                    Text(record.updatedAt.formatted(date:.abbreviated,time:.shortened)).lineLimit(1)
                }.font(.system(size:10)).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading)
            Button { service.favorite(record) } label: { Image(systemName:record.favorite ? "star.fill" : "star").foregroundStyle(record.favorite ? Color.orange : Color.secondary) }
                .buttonStyle(.plain).help(record.favorite ? "取消收藏" : "收藏")
        }
        .padding(10).frame(maxWidth:.infinity,alignment:.leading)
        .background(selection.selected?.id == record.id ? Color.accentColor.opacity(0.13) : Color.clear,in:RoundedRectangle(cornerRadius:8))
        .contentShape(Rectangle()).onTapGesture { selection.selectedID = record.id; onCopy(record) }
        .contextMenu {
            Button("复制") { onCopy(record) }
            if record.kind == .image { Button("贴到屏幕") { onPin(record) } }
            Button(record.favorite ? "取消收藏" : "收藏") { service.favorite(record) }
            Divider(); Button("删除",role:.destructive) { service.delete(record) }
        }
    }
}

struct ThumbnailView: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage:image).resizable().scaledToFit() }
            else { Image(systemName:"photo").foregroundStyle(.secondary) }
        }.task(id:url) {
            let loaded = await Task.detached(priority:.utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL,nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:160,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary)
            }.value
            guard !Task.isCancelled, let loaded else { return }
            image = NSImage(cgImage:loaded,size:.zero)
        }
    }
}
