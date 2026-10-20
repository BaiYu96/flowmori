import AppKit
import SwiftUI
import ServiceManagement
import Carbon

struct SettingsView: View {
    @ObservedObject var app: AppController
    @ObservedObject var settings: Settings
    @ObservedObject var menu: MenuBarManager
    @State private var page = "基本"
    private let pages = [("基本","slider.horizontal.3"),("快捷键","keyboard"),("剪贴板","clipboard"),("菜单栏","menubar.rectangle"),("权限","lock.shield"),("关于","info.circle")]
    var body: some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:6) {
                HStack(spacing:8) {
                    Image(systemName:"square.stack.3d.up.fill").font(.title2).foregroundStyle(.tint)
                    Text("Flowmori").font(.title3.bold())
                }.padding(.vertical,24)
                ForEach(pages,id:\.0) { item in
                    Button { page = item.0 } label: {
                        Label(item.0,systemImage:item.1).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,9).padding(.horizontal,12)
                            .background(page == item.0 ? Color.accentColor.opacity(0.14) : .clear,in:RoundedRectangle(cornerRadius:8))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("本地运行 · v0.1.0").font(.caption).foregroundStyle(.secondary).padding(.bottom,16)
            }.padding(.horizontal,16).frame(width:150).background(.ultraThinMaterial)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    Text(page).font(.system(size:25,weight:.semibold)).padding(.top,8)
                    switch page {
                    case "基本": general
                    case "快捷键": shortcuts
                    case "剪贴板": clipboard
                    case "菜单栏": menuBar
                    case "权限": permissions
                    default: about
                    }
                    Spacer(minLength:12)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(26)
            }.background(Color(nsColor:.windowBackgroundColor))
        }.frame(width:720,height:570)
        .onAppear { settings.refreshPermissions() }
    }
    private var general: some View {
        VStack(alignment:.leading,spacing:20) {
            Text("复制、截图、收纳，随时可用。").foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment:.leading,spacing:12) {
                    Toggle("登录时启动 Flowmori",isOn:Binding(get: { settings.loginStatus == .enabled || settings.loginStatus == .requiresApproval },set: { settings.setLoginEnabled($0) }))
                    Text("登录后在菜单栏后台运行，不弹出窗口。").font(.caption).foregroundStyle(.secondary)
                    if settings.loginStatus == .requiresApproval {
                        Text("等待系统批准，尚未启用登录启动。").font(.caption).foregroundStyle(.orange)
                        Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    if let error = settings.loginMessage { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
            }
            GroupBox("快速操作") {
                VStack(spacing:12) {
                    ForEach(AppAction.allCases) { action in
                        HStack { Button(action.title) { app.perform(action) }; Spacer(); Text(settings.shortcuts[action]?.display ?? "").foregroundStyle(.secondary).font(.system(.body,design:.monospaced)) }
                    }
                }.padding(8)
            }
            HStack { Button("显示／隐藏全部贴图") { app.pins.toggleAll() }; Button("关闭全部贴图") { app.pins.closeAll() } }
            if let error = app.startupError { Text(error).foregroundStyle(.orange).font(.caption).textSelection(.enabled) }
            Text("点击菜单栏图标打开收纳面板；右键可使用所有功能和退出应用。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var shortcuts: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("点击右侧组合后按下新快捷键。默认使用 Option＋单个字母。").foregroundStyle(.secondary)
            ForEach(AppAction.allCases) { action in
                HStack {
                    Text(action.title); Spacer()
                    ShortcutRecorder(shortcut:settings.shortcuts[action] ?? action.defaultShortcut) { shortcut in app.changeShortcut(action,to:shortcut) }.frame(width:150,height:32)
                }
                if let message = app.hotkeyErrors[action] { Text(message).font(.caption).foregroundStyle(.orange) }
            }
            Divider()
            Text("按 Esc 取消录制。快捷键使用期间会接管对应的 Option 字符输入；如需输入该字符，可在这里换成其他组合。").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var clipboard: some View {
        if let service = app.clipboard {
            ClipboardPreferences(service:service,settings:settings)
        } else {
            Text(app.startupError ?? "剪贴板历史暂不可用").foregroundStyle(.orange)
            Button("打开数据目录") { NSWorkspace.shared.open(app.dataDirectory) }
        }
    }
    private var menuBar: some View {
        VStack(alignment:.leading,spacing:16) {
            Toggle("启用菜单栏收纳",isOn:Binding(get:{settings.menuEnabled},set:{menu.enable($0)})).disabled(menu.operating || !menu.supported)
            Text("允许辅助功能权限后，点击「收纳全部」自动整理所有可管理图标。新启动应用的图标也会自动纳入。无需拖动分隔符。")
                .font(.callout).lineSpacing(5).foregroundStyle(.secondary)
            HStack {
                Button(menu.expanded ? "收起" : "全部展开") { menu.toggleExpanded() }.disabled(menu.operating || !settings.menuEnabled)
                Button("打开收纳面板") { app.perform(.collection) }
            }
            Text(menu.message).font(.callout).foregroundStyle(.secondary)
            Divider()
            Text("收纳面板位于刘海下方。点击条目时，Flowmori 临时移出真实图标并打开它的菜单，菜单关闭后收回。")
            Text("兼容范围：macOS 26.6.2（25G83）。时钟、控制中心等系统状态项应留在常驻区。其他系统构建会暂停收纳，等待重新验证。").font(.caption).foregroundStyle(.secondary)
            Button("辅助功能设置") { settings.requestAccessibility() }
        }
    }
    private var permissions: some View {
        VStack(alignment:.leading,spacing:18) {
            permissionRow("屏幕录制",detail:"用于区域截图。授权后若仍不可用，请重新打开 Flowmori。",granted:settings.captureGranted) { settings.requestCapture() }
            Divider()
            permissionRow("辅助功能",detail:"用于移动与点击菜单栏图标。剪贴板和贴图不依赖此权限。",granted:settings.accessibilityGranted) { settings.requestAccessibility() }
            Divider()
            VStack(alignment:.leading,spacing:8) {
                Text("剪贴板读取").font(.headline)
                Text("系统要求确认时，请允许 Flowmori 读取剪贴板。内容仅保存于本机。").font(.caption).foregroundStyle(.secondary)
                Button("检查剪贴板授权") { app.clipboard?.requestRead() }
            }
            Button("刷新权限状态") { settings.refreshPermissions(); menu.refresh() }
        }
    }
    private func permissionRow(_ title:String,detail:String,granted:Bool,action:@escaping ()->Void) -> some View {
        VStack(alignment:.leading,spacing:8) {
            HStack { Text(title).font(.headline); Spacer(); Label(granted ? "已允许" : "未允许",systemImage:granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? Color.green : .secondary) }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Button(granted ? "打开系统设置" : "前往授权",action:action)
        }
    }
    private var about: some View {
        VStack(alignment:.leading,spacing:18) {
            Label("Flowmori",systemImage:"square.stack.3d.up.fill").font(.largeTitle.bold())
            Text("版本 0.1.0 · Apple Silicon · macOS 26").foregroundStyle(.secondary)
            Text("截图贴图、剪贴板历史与菜单栏收纳。\n无账号、无云同步、无遥测，所有历史存储在本机。").lineSpacing(6)
            Text("自主实现 · MIT License").font(.headline)
            Button("打开数据目录") { NSWorkspace.shared.open(app.dataDirectory) }
            Text("剪贴板保密标记由来源应用提供，无法识别所有敏感内容。可暂停记录或排除特定应用。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ClipboardPreferences: View {
    @ObservedObject var service: ClipboardService
    @ObservedObject var settings: Settings
    @State private var confirmClear = false
    @State private var clearFavorites = false
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Toggle("暂停记录剪贴板",isOn:$settings.paused)
            HStack {
                Text("普通历史上限")
                Spacer()
                Picker("条数",selection:$settings.historyLimit) { ForEach(Array(Set([100,300,500,1000,3000,settings.historyLimit])).sorted(),id:\.self) { Text("\($0) 条").tag($0) } }.labelsHidden().frame(width:120)
            }
            Text("收藏不会自动清理。当前共有 \(service.records.count) 条历史。单条内容上限 32 MB。").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("排除应用").font(.headline)
            Text("每行填写一个应用 Bundle ID。下方按钮可从应用文件自动添加。").font(.caption).foregroundStyle(.secondary)
            TextEditor(text:$settings.exclusions).font(.system(.caption,design:.monospaced)).frame(height:95).border(.quaternary)
            Button("选择要排除的应用…") {
                let dialog = NSOpenPanel(); dialog.directoryURL = URL(fileURLWithPath:"/Applications"); dialog.allowedContentTypes = [.application]; dialog.canChooseDirectories = false
                if dialog.runModal() == .OK, let url = dialog.url, let id = Bundle(url:url)?.bundleIdentifier, !settings.excludedBundleIDs.contains(id) {
                    settings.exclusions += (settings.exclusions.isEmpty ? "" : "\n") + id
                }
            }
            Divider()
            Toggle("清空时包含收藏",isOn:$clearFavorites)
            Button("清空历史…",role:.destructive) { confirmClear = true }
                .alert("清空\(clearFavorites ? "全部" : "普通")历史？",isPresented:$confirmClear) {
                    Button("取消",role:.cancel) {}
                    Button("清空",role:.destructive) { service.clear(includeFavorites:clearFavorites) }
                } message: { Text("该操作无法撤销，不会清空当前系统剪贴板。") }
            Text(service.status).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: Shortcut
    let onChange: (Shortcut) -> Void
    func makeNSView(context:Context) -> RecorderButton { let button = RecorderButton(); button.onChange = onChange; return button }
    func updateNSView(_ view:RecorderButton,context:Context) { view.shortcut = shortcut; view.onChange = onChange; if !view.recording { view.title = shortcut.display } }
}
final class RecorderButton: NSButton {
    private static weak var activeRecorder: RecorderButton?
    var shortcut = AppAction.history.defaultShortcut
    var recording = false
    var onChange: ((Shortcut) -> Void)?
    init() { super.init(frame:.zero); bezelStyle = .rounded; target = self; action = #selector(begin); font = .monospacedSystemFont(ofSize:14,weight:.medium) }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    @objc private func begin() {
        Self.activeRecorder?.cancelRecording()
        Self.activeRecorder = self; recording = true; title = "按组合键…"; window?.makeFirstResponder(self)
    }
    private func cancelRecording() {
        recording = false; title = shortcut.display
        if Self.activeRecorder === self { Self.activeRecorder = nil }
    }
    private func finish(_ value:Shortcut) { cancelRecording(); onChange?(value); title = shortcut.display }
    static func captureRegisteredShortcut(_ shortcut:Shortcut) -> Bool {
        guard let recorder = activeRecorder, recorder.recording else { return false }
        guard recorder.window?.isKeyWindow == true else { recorder.cancelRecording(); return false }
        recorder.finish(shortcut); return true
    }
    override func resignFirstResponder() -> Bool { cancelRecording(); return true }
    override func keyDown(with event:NSEvent) {
        guard recording else { super.keyDown(with:event); return }
        if event.keyCode == 53 { cancelRecording(); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command,.option,.control]).isEmpty else { title = "请带上修饰键"; return }
        let labels: [UInt16:String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",49:"Space",50:"`",36:"Return",48:"Tab"]
        guard let label = labels[event.keyCode] else { title = "请选择字母或数字"; return }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        finish(Shortcut(keyCode:UInt32(event.keyCode),modifiers:modifiers,label:label))
    }
}
