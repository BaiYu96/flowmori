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
struct DirectActivation {
    let performed: Bool
    let supported: [String]
    let action: String
    let error: AXError
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
    /// The caller must ignore a non-success AXError if the UI actually appears:
    /// macOS can return cannotComplete even when the menu was opened.
    static func activate(_ owner:MenuBarOwner, frame:CGRect, label:String, right:Bool) -> DirectActivation {
        let app = AXUIElementCreateApplication(owner.pid)
        AXUIElementSetMessagingTimeout(app,0.5)
        guard let bar = attribute(app,kAXExtrasMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else {
            return DirectActivation(performed:false,supported:[],action:"",error:.cannotComplete)
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
        guard let target else { return DirectActivation(performed:false,supported:[],action:"",error:.invalidUIElement) }
        let action = right ? "AXShowMenu" : (kAXPressAction as String)
        guard target.3.contains(action) else {
            return DirectActivation(performed:false,supported:target.3,action:action,error:.actionUnsupported)
        }
        let error = AXUIElementPerformAction(target.0,action as CFString)
        return DirectActivation(performed:true,supported:target.3,action:action,error:error)
    }
    private static func attribute(_ element:AXUIElement,_ name:String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element,name as CFString,&result) == .success ? result : nil
    }
}
