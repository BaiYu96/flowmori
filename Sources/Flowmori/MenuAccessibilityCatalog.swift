import AppKit
import ApplicationServices

struct MenuBarOwner: Sendable {
    let pid: pid_t
    let bundleID: String
    let name: String
}
struct AccessibleMenuItem: Sendable {
    let owner: MenuBarOwner
    let frame: CGRect
    let label: String
    let actions: [String]
}
private struct ActivationPlan {
    let supported: [String]
    let action: String
    let target: AXUIElement?
    let error: AXError
}
/// AXPress does not return until the source menu's tracking loop settles, but
/// the menu itself is already visible after ~0.1s. Run the press on its own
/// thread and poll the menu concurrently instead of paying that latency.
private final class ActivationRequest: @unchecked Sendable {
    private let target: AXUIElement
    private let action: String
    init(target:AXUIElement,action:String) { self.target=target; self.action=action }
    func perform() {
        DispatchQueue.global(qos:.userInitiated).async { [self] in
            let started=ProcessInfo.processInfo.systemUptime
            let error=AXUIElementPerformAction(target,action as CFString)
            inlineDebugLog("source press return action=\(action) error=\(error.rawValue) elapsed=\(String(format:"%.3f",ProcessInfo.processInfo.systemUptime-started))")
        }
    }
}
struct InlineMenuPreparation: Sendable {
    enum Failure: Sendable {
        case unavailable, noMenu, emptyMenu, cancelled
    }
    let nodes: [InlineMenuNode]
    let action: String
    let supported: [String]
    let error: AXError
    let failure: Failure?
}

/// macOS 26 renders third-party status items inside Control Center. Their
/// application identity comes from the original application's extra menu bar.
enum MenuAccessibilityCatalog {
    static func scan(_ owners:[MenuBarOwner]) -> [AccessibleMenuItem] {
        var result: [AccessibleMenuItem] = []
        for owner in owners {
            let app = AXUIElementCreateApplication(owner.pid)
            AXUIElementSetMessagingTimeout(app,0.08)
            guard let bar = attribute(app,kAXExtrasMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { continue }
            let menu = unsafeBitCast(bar,to:AXUIElement.self)
            for item in attribute(menu,kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                guard let position = attribute(item,kAXPositionAttribute), let size = attribute(item,kAXSizeAttribute),
                      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { continue }
                var point = CGPoint.zero, dimensions = CGSize.zero
                guard AXValueGetValue(unsafeBitCast(position,to:AXValue.self),.cgPoint,&point),
                      AXValueGetValue(unsafeBitCast(size,to:AXValue.self),.cgSize,&dimensions),
                      dimensions.width > 0, dimensions.height > 0 else { continue }
                let label = (attribute(item,kAXDescriptionAttribute) as? String) ?? (attribute(item,kAXTitleAttribute) as? String) ?? owner.name
                var actions: CFArray?
                let actionError = AXUIElementCopyActionNames(item,&actions)
                let names = actionError == .success ? (actions as? [String] ?? []) : []
                result.append(AccessibleMenuItem(owner:owner,frame:CGRect(origin:point,size:dimensions),label:label,actions:names))
            }
        }
        return result
    }
    /// Re-resolve the live AX element immediately before synthetic activation.
    private static func resolve(_ owner:MenuBarOwner, frame:CGRect, label:String, right:Bool) -> ActivationPlan {
        let app = AXUIElementCreateApplication(owner.pid)
        AXUIElementSetMessagingTimeout(app,0.5)
        guard let bar = attribute(app,kAXExtrasMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else {
            return ActivationPlan(supported:[],action:"",target:nil,error:.cannotComplete)
        }
        let menu = unsafeBitCast(bar,to:AXUIElement.self)
        var candidates: [(AXUIElement,CGRect,String,[String])] = []
        for item in attribute(menu,kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            guard let position = attribute(item,kAXPositionAttribute), let size = attribute(item,kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { continue }
            var point = CGPoint.zero, dimensions = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(position,to:AXValue.self),.cgPoint,&point),
                  AXValueGetValue(unsafeBitCast(size,to:AXValue.self),.cgSize,&dimensions),
                  dimensions.width > 0, dimensions.height > 0 else { continue }
            let itemLabel = (attribute(item,kAXDescriptionAttribute) as? String) ?? (attribute(item,kAXTitleAttribute) as? String) ?? owner.name
            var actions: CFArray?
            let error = AXUIElementCopyActionNames(item,&actions)
            let names = error == .success ? (actions as? [String] ?? []) : []
            candidates.append((item,CGRect(origin:point,size:dimensions),itemLabel,names))
        }
        let sameLabel = candidates.filter { $0.2 == label }
        let target = (sameLabel.isEmpty ? candidates : sameLabel).min {
            let left = abs($0.1.minX-frame.minX)+abs($0.1.midY-frame.midY)
            let right = abs($1.1.minX-frame.minX)+abs($1.1.midY-frame.midY)
            return left < right
        }
        guard let target else { return ActivationPlan(supported:[],action:"",target:nil,error:.invalidUIElement) }
        let action = right ? "AXShowMenu" : (kAXPressAction as String)
        guard target.3.contains(action) else {
            return ActivationPlan(supported:target.3,action:action,target:target.0,error:.actionUnsupported)
        }
        return ActivationPlan(supported:target.3,action:action,target:target.0,error:.success)
    }
    private static func start(_ plan:ActivationPlan) {
        guard let target=plan.target, plan.supported.contains(plan.action) else { return }
        ActivationRequest(target:target,action:plan.action).perform()
    }
    /// Perform the slow AX activation and snapshot away from the main thread.
    /// The returned node tree is immutable, so it can be presented later without
    /// retaining AX elements that die when the source menu closes.
    static func prepare(owner:MenuBarOwner, frame:CGRect, label:String, right:Bool, request:InlinePreparationRequest = InlinePreparationRequest()) -> InlineMenuPreparation {
        guard !request.isCancelled, sessionAllowsInput() else {
            return InlineMenuPreparation(nodes:[],action:"",supported:[],error:.cannotComplete,failure:.cancelled)
        }
        var plan = resolve(owner,frame:frame,label:label,right:right)
        if right && (plan.target == nil || plan.error == .actionUnsupported) {
            plan = resolve(owner,frame:frame,label:label,right:false)
        }
        let started = ProcessInfo.processInfo.systemUptime
        guard let target = plan.target, plan.supported.contains(plan.action) else {
            return InlineMenuPreparation(nodes:[],action:plan.action,supported:plan.supported,
                                         error:plan.error,failure:.unavailable)
        }
        guard !request.isCancelled else {
            return InlineMenuPreparation(nodes:[],action:plan.action,supported:plan.supported,error:.cannotComplete,failure:.cancelled)
        }
        start(plan)
        var menu: AXUIElement?
        var nodes: [InlineMenuNode] = []
        var opened = false
        for _ in 0..<16 {
            guard !request.isCancelled, sessionAllowsInput() else {
                if let menu { _ = cancel(menu) }
                return InlineMenuPreparation(nodes:[],action:plan.action,supported:plan.supported,
                                             error:plan.error,failure:.cancelled)
            }
            if ProcessInfo.processInfo.systemUptime - started >= 1.5 { break }
            if menu == nil { menu = menuElement(for:target) }
            if let menu, menuIsOpen(menu) {
                opened = true
                inlineDebugLog("source menu opened elapsed=\(String(format:"%.3f",ProcessInfo.processInfo.systemUptime-started))")
                let snapshotStarted = ProcessInfo.processInfo.systemUptime
                let snapshot = Self.nodes(in:menu, deadline:started + 1.5, request:request)
                inlineDebugLog("source snapshot nodes=\(snapshot.count) elapsed=\(String(format:"%.3f",ProcessInfo.processInfo.systemUptime-snapshotStarted))")
                if !snapshot.isEmpty { nodes = snapshot; break }
            }
            usleep(50_000)
        }
        guard let menu, opened else {
            if let menu, menuIsOpen(menu) { _ = cancel(menu) }
            return InlineMenuPreparation(nodes:[],action:plan.action,supported:plan.supported,
                                         error:.cannotComplete,failure:.noMenu)
        }
        guard !nodes.isEmpty else {
            _ = cancel(menu)
            return InlineMenuPreparation(nodes:[],action:plan.action,supported:plan.supported,
                                         error:.success,failure:.emptyMenu)
        }
        let cancelStarted = ProcessInfo.processInfo.systemUptime
        _ = cancel(menu)
        // macOS may keep the source menu on screen briefly after AXCancel. Wait
        // only until it is gone; a fixed delay made every icon click feel slow.
        var closed = false
        for _ in 0..<16 {
            if !menuIsOpen(menu) { closed = true; break }
            usleep(10_000)
        }
        inlineDebugLog("source cancel closed=\(closed) elapsed=\(String(format:"%.3f",ProcessInfo.processInfo.systemUptime-cancelStarted)) total=\(String(format:"%.3f",ProcessInfo.processInfo.systemUptime-started))")
        usleep(10_000)
        return InlineMenuPreparation(nodes:nodes,action:plan.action,supported:plan.supported,
                                     error:.success,failure:nil)
    }
    private static func sessionAllowsInput() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String:Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) != true &&
               (session[kCGSessionOnConsoleKey as String] as? Bool) == true
    }
    /// The AXMenu child can appear a few milliseconds after AXPress returns.
    static func menuElement(for target:AXUIElement) -> AXUIElement? {
        (attribute(target,kAXChildrenAttribute) as? [AXUIElement])?.first {
            (attribute($0,kAXRoleAttribute) as? String) == "AXMenu"
        }
    }
    /// A real menu reports a non-empty AX frame only while it is presented.
    /// A closed AXMenu still exposes its children, so size is the reliable signal.
    static func menuIsOpen(_ menu:AXUIElement) -> Bool {
        guard let size = attribute(menu,kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return false }
        var dimensions = CGSize.zero
        return AXValueGetValue(unsafeBitCast(size,to:AXValue.self),.cgSize,&dimensions) && dimensions.width > 1 && dimensions.height > 1
    }
    static func snapshot(_ menu:AXUIElement) -> [InlineMenuNode] {
        nodes(in:menu)
    }
    static func press(_ element:AXUIElement) -> AXError {
        AXUIElementPerformAction(element,kAXPressAction as CFString)
    }
    /// Re-open the status-item menu, walk to the same item path, and press it
    /// while the native menu is still alive. Elements captured for the inline
    /// snapshot are usually invalidated when the menu closes.
    static func press(owner:MenuBarOwner,frame:CGRect,label:String,path:[Int],expected:[[String]]) -> AXError {
        guard sessionAllowsInput(), !Task.isCancelled else { return .cannotComplete }
        let plan = resolve(owner,frame:frame,label:label,right:false)
        inlineDebugLog("source activate action=\(plan.action) error=\(plan.error.rawValue) supported=\(plan.supported)")
        guard let target = plan.target, plan.supported.contains(plan.action) else { return plan.error }
        start(plan)
        var menu: AXUIElement?
        var opened = false
        for _ in 0..<40 {
            if menu == nil { menu = menuElement(for:target) }
            if let menu, menuIsOpen(menu) { opened = true; break }
            usleep(25_000)
        }
        inlineDebugLog("source menu open=\(opened) sizeOpen=\(menu.map { menuIsOpen($0) } ?? false)")
        guard let menu, opened else {
            if let menu { _ = cancel(menu) }
            return .invalidUIElement
        }
        var current = menu
        for (depth,index) in path.enumerated() {
            guard sessionAllowsInput(), !Task.isCancelled else { _ = cancel(menu); return .cannotComplete }
            let items = menuItems(in:current)
            let titles = items.map { attribute($0,kAXTitleAttribute) as? String ?? "" }
            guard InlineMenuSelection.matches(titles,expected:expected,depth:depth),
                  index >= 0, index < items.count else {
                _ = cancel(menu)
                return .invalidUIElement
            }
            let item = items[index]
            guard attribute(item,kAXEnabledAttribute) as? Bool == true else {
                _ = cancel(menu); return .actionUnsupported
            }
            if depth == path.count - 1 {
                let error = AXUIElementPerformAction(item,kAXPressAction as CFString)
                usleep(80_000)
                _ = cancel(menu)
                return error
            }
            _ = AXUIElementPerformAction(item,kAXPressAction as CFString)
            guard let submenu = (attribute(item,kAXChildrenAttribute) as? [AXUIElement])?.first(where: {
                (attribute($0,kAXRoleAttribute) as? String) == kAXMenuRole as String
            }), waitUntilOpen(submenu) else {
                _ = cancel(menu)
                return .cannotComplete
            }
            current = submenu
        }
        _ = cancel(menu)
        return .invalidUIElement
    }
    private static func waitUntilOpen(_ menu:AXUIElement) -> Bool {
        for _ in 0..<40 {
            if menuIsOpen(menu) { return true }
            usleep(25_000)
        }
        return false
    }
    private static func menuItems(in menu:AXUIElement) -> [AXUIElement] {
        (attribute(menu,kAXChildrenAttribute) as? [AXUIElement] ?? []).filter {
            (attribute($0,kAXRoleAttribute) as? String) == kAXMenuItemRole as String
        }
    }
    static func cancel(_ menu:AXUIElement) -> Bool {
        AXUIElementPerformAction(menu,kAXCancelAction as CFString) == .success
    }
    private static func nodes(in menu:AXUIElement, deadline:TimeInterval = .infinity, request:InlinePreparationRequest? = nil) -> [InlineMenuNode] {
        var result: [InlineMenuNode] = []
        let keys = [kAXRoleAttribute,kAXTitleAttribute,kAXEnabledAttribute,
                    kAXMenuItemMarkCharAttribute,kAXMenuItemCmdCharAttribute,kAXChildrenAttribute]
        for child in attribute(menu,kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            guard ProcessInfo.processInfo.systemUptime < deadline, request?.isCancelled != true else { return [] }
            let values = multipleAttributes(child,keys)
            guard values.count == keys.count, (values[0] as? String) == kAXMenuItemRole as String else { continue }
            let title = (values[1] as? String) ?? ""
            let enabled = (values[2] as? Bool) ?? false
            let mark = (values[3] as? String) ?? ""
            let key = (values[4] as? String) ?? ""
            let shortcut = key.isEmpty || key == " " ? nil : "⌘\(key)"
            var children: [InlineMenuNode] = []
            if let submenu = (values[5] as? [AXUIElement])?.first(where: {
                (attribute($0,kAXRoleAttribute) as? String) == "AXMenu"
            }) {
                children = nodes(in:submenu,deadline:deadline,request:request)
            }
            var actions: CFArray?
            let error = AXUIElementCopyActionNames(child,&actions)
            let names = error == .success ? (actions as? [String] ?? []) : []
            result.append(InlineMenuNode(title:title,enabled:enabled,
                checked:!mark.isEmpty,shortcut:shortcut,canPress:names.contains(kAXPressAction as String),
                children:children))
        }
        return result
    }
    private static func multipleAttributes(_ element:AXUIElement,_ keys:[String]) -> [AnyObject] {
        AXUIElementSetMessagingTimeout(element,0.15)
        var value: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element,keys as CFArray,[],&value)
        guard error == .success, let value = value as? [AnyObject] else {
            return keys.map { attribute(element,$0) as AnyObject? ?? NSNull() }
        }
        return value
    }
    private static func attribute(_ element:AXUIElement,_ name:String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element,0.15)
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element,name as CFString,&result) == .success ? result : nil
    }
}
