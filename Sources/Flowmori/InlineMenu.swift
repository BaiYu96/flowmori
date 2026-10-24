import AppKit
import ApplicationServices
import Foundation

func inlineDebugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["FLOWMORI_INLINE_DEBUG"] != nil else { return }
    let line = "\(Date().timeIntervalSince1970) \(message())\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/flowmori-inline-debug.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

final class InlineMenuNode: @unchecked Sendable {
    let title: String
    let enabled: Bool
    let checked: Bool
    let shortcut: String?
    let canPress: Bool
    let children: [InlineMenuNode]

    init(title:String,enabled:Bool,checked:Bool,shortcut:String?,canPress:Bool,children:[InlineMenuNode]) {
        self.title = title
        self.enabled = enabled
        self.checked = checked
        self.shortcut = shortcut
        self.canPress = canPress
        self.children = children
    }

    var isSeparator: Bool { title.isEmpty && !enabled && children.isEmpty }
}

/// Refuse stale positional paths when a dynamic source menu changes.
enum InlineMenuSelection {
    static func levels(nodes: [InlineMenuNode], path: [Int]) -> [[String]]? {
        guard !path.isEmpty else { return nil }
        var current = nodes
        var result: [[String]] = []
        for (depth, index) in path.enumerated() {
            guard current.indices.contains(index) else { return nil }
            let node = current[index]
            guard node.enabled, !node.isSeparator else { return nil }
            result.append(current.map(\.title))
            if depth == path.count - 1 {
                guard node.children.isEmpty, node.canPress else { return nil }
            }
            current = node.children
        }
        return result
    }
    static func matches(_ titles: [String], expected: [[String]], depth: Int) -> Bool {
        expected.indices.contains(depth) && titles == expected[depth]
    }
}

/// A synchronous AX call cannot be interrupted. Keep its result behind a lock
/// so the UI can stop waiting at its deadline and discard late completion.
final class InlinePreparationRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var result: InlineMenuPreparation?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func complete(_ value: InlineMenuPreparation) {
        lock.lock(); defer { lock.unlock() }
        if !stopped { result = value }
    }
    func read() -> InlineMenuPreparation? { lock.lock(); defer { lock.unlock() }; return result }
}

/// Rebuilds the source application's menu as a native NSMenu at the click
/// location. The source menu window itself is owned by the other process and
/// cannot be reparented, but the native control keeps the original hierarchy,
/// shortcuts, checkmarks, sizing, keyboard navigation, and submenus.
@MainActor final class NativeInlineMenuPresenter: NSObject, NSMenuDelegate {
    private final class PathBox: NSObject {
        let path: [Int]
        init(path:[Int]) { self.path = path }
    }
    private var menu: NSMenu?
    private var onSelect: (([Int]) -> Void)?
    private var onCancel: (() -> Void)?
    private var selected = false
    private var closed = false

    func present(nodes:[InlineMenuNode],at point:NSPoint,onSelect:@escaping ([Int]) -> Void,onCancel:@escaping () -> Void) {
        self.onSelect = onSelect
        self.onCancel = onCancel
        selected = false
        closed = false
        let menu = build(nodes,prefix:[])
        menu.delegate = self
        self.menu = menu
        let visible = NSApp.windows.filter(\.isVisible)
        let window = visible.filter { $0.frame.contains(point) }
            .max { $0.level.rawValue < $1.level.rawValue }
        let windows = visible.map { "\($0.windowNumber):\($0.level.rawValue):\(NSStringFromRect($0.frame)):key=\($0.isKeyWindow):main=\($0.isMainWindow)" }
        inlineDebugLog("present nodes=\(nodes.count) point=\(point) active=\(NSApp.isActive) key=\(String(describing: NSApp.keyWindow?.windowNumber)) chosen=\(String(describing: window?.windowNumber)) windows=\(windows)")
        window?.makeKeyAndOrderFront(nil)
        inlineDebugLog("after focus active=\(NSApp.isActive) key=\(String(describing: NSApp.keyWindow?.windowNumber)) chosenKey=\(String(describing: window?.isKeyWindow))")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { [weak self] in
            guard let self else { return }
            let visible = NSApp.windows.filter(\.isVisible).map { "\($0.windowNumber):\($0.level.rawValue):\(NSStringFromRect($0.frame)):key=\($0.isKeyWindow)" }
            inlineDebugLog("during popUp active=\(NSApp.isActive) key=\(String(describing: NSApp.keyWindow?.windowNumber)) closed=\(self.closed) appWindows=\(visible)")
        }
        var shown = false
        if let view = window?.contentView, let window = view.window {
            let inWindow = window.convertPoint(fromScreen: point)
            let local = view.convert(inWindow, from:nil)
            inlineDebugLog("popUp view window=\(window.windowNumber) inWindow=\(inWindow) local=\(local) viewFrame=\(NSStringFromRect(view.frame))")
            shown = menu.popUp(positioning:nil, at:local, in:view)
        } else {
            inlineDebugLog("popUp nil window fallback")
            shown = menu.popUp(positioning:nil, at:point, in:nil)
        }
        inlineDebugLog("popUp returned shown=\(shown) closed=\(closed) selected=\(selected)")
        if !shown, !closed { menuDidClose(menu) }
    }

    func cancel() {
        menu?.cancelTracking()
        menu = nil
    }

    private func build(_ nodes:[InlineMenuNode],prefix:[Int]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index,node) in nodes.enumerated() {
            if node.isSeparator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title:node.title.isEmpty ? "未命名项" : node.title,action:nil,keyEquivalent:"")
            item.isEnabled = node.enabled && (!node.children.isEmpty || node.canPress)
            item.state = node.checked ? .on : .off
            if let shortcut = node.shortcut {
                let key = shortcut.replacingOccurrences(of:"⌘",with:"").lowercased()
                if key.count == 1 { item.keyEquivalent = key; item.keyEquivalentModifierMask = .command }
            }
            let path = prefix + [index]
            if node.children.isEmpty {
                let box = PathBox(path:path)
                item.representedObject = box
                item.target = self
                item.action = #selector(choose(_:))
            } else {
                item.submenu = build(node.children,prefix:path)
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func choose(_ sender:NSMenuItem) {
        guard let box = sender.representedObject as? PathBox else { return }
        inlineDebugLog("choose path=\(box.path) onSelect=\(onSelect != nil)")
        selected = true
        onSelect?(box.path)
    }

    func menuDidClose(_ menu:NSMenu) {
        guard !closed else { return }
        closed = true
        menu.delegate = nil
        self.menu = nil
        guard !selected else { return }
        // AppKit can send menuDidClose before the selected item's action.
        // Defer the cancel decision one run-loop turn so choose(_:) can run.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.selected else { return }
            self.onCancel?()
        }
    }
}
