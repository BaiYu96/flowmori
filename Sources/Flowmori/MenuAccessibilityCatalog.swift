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
                result.append(AccessibleMenuItem(owner:owner,frame:CGRect(origin:point,size:dimensions),label:label))
            }
        }
        return result
    }
    private static func attribute(_ element:AXUIElement,_ name:String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element,name as CFString,&result) == .success ? result : nil
    }
}
