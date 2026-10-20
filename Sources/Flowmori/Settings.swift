import AppKit
import Combine
import ServiceManagement
import Carbon
import FlowmoriCore

enum AppAction: String, CaseIterable, Codable, Identifiable {
    case history, capture, pin, collection
    var id: String { rawValue }
    var title: String {
        switch self { case .history: return "剪贴板历史"; case .capture: return "区域截图"
        case .pin: return "贴出剪贴板图片"; case .collection: return "菜单栏收纳" }
    }
    var defaultShortcut: Shortcut {
        switch self {
        case .history: return Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey), label: "V")
        case .capture: return Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey), label: "A")
        case .pin: return Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey), label: "P")
        case .collection: return Shortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(optionKey), label: "M")
        }
    }
}
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
    var display: String {
        (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") +
        (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") +
        (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") +
        (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + label.uppercased()
    }
    func matches(_ other: Shortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
}

@MainActor final class Settings: ObservableObject {
    private let defaults: UserDefaults
    @Published var historyLimit: Int { didSet { defaults.set(historyLimit, forKey:"historyLimit") } }
    @Published var paused: Bool = false
    @Published var exclusions: String { didSet { defaults.set(exclusions,forKey:"exclusions") } }
    @Published var menuEnabled: Bool { didSet { defaults.set(menuEnabled,forKey:"menuEnabled") } }
    @Published var shortcuts: [AppAction: Shortcut] = [:]
    @Published var loginStatus: SMAppService.Status = .notRegistered
    @Published var loginMessage: String?
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var captureGranted = CGPreflightScreenCaptureAccess()
    var excludedBundleIDs: Set<String> {
        Set(exclusions.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty })
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        historyLimit = defaults.object(forKey:"historyLimit") == nil ? 500 : max(1,min(defaults.integer(forKey:"historyLimit"),10000))
        exclusions = defaults.string(forKey:"exclusions") ?? "com.agilebits.onepassword7\ncom.1password.1password\norg.keepassxc.keepassxc\ncom.apple.keychainaccess"
        menuEnabled = defaults.bool(forKey:"menuEnabled")
        for action in AppAction.allCases {
            if let data = defaults.data(forKey:"hotkey.\(action.rawValue)"), let key = try? JSONDecoder().decode(Shortcut.self,from:data) {
                shortcuts[action] = key
            } else { shortcuts[action] = action.defaultShortcut }
        }
        refreshPermissions()
    }
    func saveShortcut(_ shortcut: Shortcut, for action: AppAction) {
        shortcuts[action] = shortcut
        defaults.set(try? JSONEncoder().encode(shortcut),forKey:"hotkey.\(action.rawValue)")
    }
    func configureFirstLaunch() -> Bool {
        let first = !defaults.bool(forKey:"hasLaunched")
        if first {
            defaults.set(true,forKey:"hasLaunched")
            if let enabled = defaults.object(forKey:ProductMigration.loginIntentKey) as? Bool {
                setLoginEnabled(enabled)
            } else if defaults.bool(forKey:ProductMigration.completedKey) {
                loginMessage = "旧版未记录登录启动意愿。请确认是否需要登录时启动 Flowmori。"
            } else { setLoginEnabled(true) }
        }
        return first
    }
    func refreshPermissions() {
        let accessibility = AXIsProcessTrusted(), capture = CGPreflightScreenCaptureAccess()
        let login = SMAppService.mainApp.status
        if accessibilityGranted != accessibility { accessibilityGranted = accessibility }
        if captureGranted != capture { captureGranted = capture }
        if loginStatus != login { loginStatus = login }
    }
    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled && SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            else if !enabled && SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            loginMessage = nil
        } catch { loginMessage = "登录启动设置失败：\(error.localizedDescription)" }
        loginStatus = SMAppService.mainApp.status
        if loginMessage == nil { defaults.set(enabled,forKey:"loginRequested") }
        if loginStatus == .requiresApproval { loginMessage = "请在系统设置的「登录项与扩展」中允许 Flowmori。" }
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacy("Privacy_Accessibility")
    }
    func requestCapture() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermissions()
        if !captureGranted { openPrivacy("Privacy_ScreenCapture") }
    }
    func openPrivacy(_ anchor: String) {
        if let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
}

@MainActor final class HotkeyManager {
    private var refs: [AppAction: EventHotKeyRef] = [:]
    private var registrations: [AppAction: Shortcut] = [:]
    private var handler: EventHandlerRef?
    var onAction: ((AppAction) -> Void)?
    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == 0x464D4F52 else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(pointer).takeUnretainedValue()
            let index = Int(id.id) - 1
            guard AppAction.allCases.indices.contains(index) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { manager.onAction?(AppAction.allCases[index]) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    deinit {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
    func register(_ action: AppAction, shortcut: Shortcut, current: [AppAction: Shortcut]) throws {
        if current.contains(where: { $0.key != action && $0.value.matches(shortcut) }) {
            throw NSError(domain:"Flowmori",code:1,userInfo:[NSLocalizedDescriptionKey:"这个组合已用于另一项 Flowmori 功能。"])
        }
        if registrations[action]?.matches(shortcut) == true { return }
        var newRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x464D4F52, id: UInt32(AppAction.allCases.firstIndex(of:action)! + 1))
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &newRef)
        guard result == noErr, let newRef else {
            throw NSError(domain:"Flowmori",code:Int(result),userInfo:[NSLocalizedDescriptionKey:"\(shortcut.display) 注册失败（\(result)）。它可能正被系统或其他应用使用，请设置其他组合。"])
        }
        if let old = refs[action] { UnregisterEventHotKey(old) }
        refs[action] = newRef
        registrations[action] = shortcut
    }
    func unregisterAll() { for ref in refs.values { UnregisterEventHotKey(ref) }; refs.removeAll(); registrations.removeAll() }
}
