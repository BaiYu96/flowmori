import AppKit
import FlowmoriCore

@MainActor final class PinController {
    private var pins: [UUID: NSPanel] = [:]
    private var hidden = false
    var onMessage: ((String) -> Void)?
    var onCopy: ((Data) -> Void)?
    var count: Int { pins.count }
    func pin(_ image: NSImage) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let scale = min(max(1,80/image.size.width,60/image.size.height),
                        min(600,screen.visibleFrame.width)/image.size.width,
                        min(500,screen.visibleFrame.height)/image.size.height)
        let size = CGSize(width:image.size.width*scale,height:image.size.height*scale)
        let rect = ScreenGeometry.clamped(CGRect(x:NSEvent.mouseLocation.x+12,y:NSEvent.mouseLocation.y-size.height-12,width:size.width,height:size.height),to:screen.visibleFrame)
        let panel = NSPanel(contentRect:rect,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        let id = UUID(), view = PinView(frame:NSRect(origin:.zero,size:size),image:image)
        view.onClose = { [weak self] in self?.pins.removeValue(forKey:id)?.close() }
        view.onCopy = { [weak self] in
            guard let cgImage = image.cgImage(forProposedRect:nil,context:nil,hints:nil),
                  let png = NSBitmapImageRep(cgImage:cgImage).representation(using:.png,properties:[:]) else { return }
            self?.onCopy?(png); self?.onMessage?("贴图已复制")
        }
        view.onSave = { [weak panel] in
            let dialog = NSSavePanel(); dialog.allowedContentTypes = [.png]; dialog.nameFieldStringValue = "Flowmori-\(Date().formatted(.iso8601.year().month().day().timeSeparator(.omitted).dateSeparator(.dash))) .png".replacingOccurrences(of:" .",with:".")
            NSApp.activate(ignoringOtherApps:true)
            dialog.begin { response in
                guard response == .OK, let url = dialog.url, let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil),
                      let png = NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) else { return }
                do { try png.write(to:url,options:.atomic) } catch { NSAlert(error:error).runModal() }
                panel?.orderFrontRegardless()
            }
        }
        if hidden { pins.values.forEach { $0.orderFrontRegardless() } }
        panel.contentView = view; pins[id] = panel; hidden = false; panel.orderFrontRegardless()
    }
    func toggleAll() {
        hidden.toggle()
        pins.values.forEach { hidden ? $0.orderOut(nil) : $0.orderFrontRegardless() }
    }
    func closeAll() { pins.values.forEach { $0.close() }; pins.removeAll(); hidden = false }
    func constrainToScreens() {
        for panel in pins.values {
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(panel.frame) }) { continue }
            let screen = NSScreen.screens.max { lhs,rhs in
                let l = lhs.visibleFrame.intersection(panel.frame), r = rhs.visibleFrame.intersection(panel.frame)
                return (l.isNull ? 0 : l.width*l.height) < (r.isNull ? 0 : r.width*r.height)
            } ?? NSScreen.main
            if let screen { panel.setFrame(ScreenGeometry.scaledImageFrame(panel.frame,factor:1,available:screen.visibleFrame),display:true) }
        }
    }
}

final class PinView: NSView {
    let image: NSImage
    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    private let toolbar = NSVisualEffectView()
    private var tracking: NSTrackingArea?
    init(frame:NSRect,image:NSImage) {
        self.image = image; super.init(frame:frame)
        wantsLayer = true; layer?.cornerRadius = 8; layer?.masksToBounds = true
        toolbar.material = .hudWindow; toolbar.blendingMode = .withinWindow; toolbar.state = .active
        toolbar.wantsLayer = true; toolbar.layer?.cornerRadius = 6; toolbar.alphaValue = 0
        let stack = NSStackView(); stack.spacing = 6; stack.orientation = .horizontal
        for (symbol,tip,selector) in [("doc.on.doc","复制",#selector(copyImage)),("square.and.arrow.down","保存",#selector(saveImage)),("xmark","关闭",#selector(closeImage))] {
            let button = NSButton(image:NSImage(systemSymbolName:symbol,accessibilityDescription:tip)!,target:self,action:selector)
            button.bezelStyle = .accessoryBarAction; button.isBordered = false; button.toolTip = tip
            stack.addArrangedSubview(button)
        }
        toolbar.addSubview(stack); addSubview(toolbar)
        stack.translatesAutoresizingMaskIntoConstraints = false; toolbar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo:topAnchor,constant:6),toolbar.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-6),
            stack.leadingAnchor.constraint(equalTo:toolbar.leadingAnchor,constant:8),stack.trailingAnchor.constraint(equalTo:toolbar.trailingAnchor,constant:-8),
            stack.topAnchor.constraint(equalTo:toolbar.topAnchor,constant:5),stack.bottomAnchor.constraint(equalTo:toolbar.bottomAnchor,constant:-5)
        ])
        toolTip = "拖动移动 · 滚轮或双指缩放 · 右键操作"
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        image.draw(in:bounds,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event:NSEvent) { toolbar.alphaValue = 1 }
    override func mouseExited(with event:NSEvent) { toolbar.alphaValue = 0 }
    override func mouseDown(with event:NSEvent) { window?.performDrag(with:event) }
    override func scrollWheel(with event:NSEvent) { resize(by:pow(1.015,event.scrollingDeltaY)) }
    override func magnify(with event:NSEvent) { resize(by:1+event.magnification) }
    private func resize(by factor:CGFloat) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(ScreenGeometry.scaledImageFrame(window.frame,factor:factor,available:screen.visibleFrame),display:true)
        needsDisplay = true
    }
    override func menu(for event:NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title,selector) in [("复制图片",#selector(copyImage)),("保存 PNG…",#selector(saveImage)),("关闭贴图",#selector(closeImage))] {
            let item = NSMenuItem(title:title,action:selector,keyEquivalent:""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc private func copyImage() { onCopy?() }
    @objc private func saveImage() { onSave?() }
    @objc private func closeImage() { onClose?() }
}
