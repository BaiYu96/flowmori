import AppKit
import Testing
@testable import Flowmori

@MainActor @Suite struct InlineCaptureViewTests {
    @Test func selectionMovesAndConfirmCopiesTheSelectedCrop() throws {
        _ = NSApplication.shared
        let image = try makeImage(width: 200, height: 150)
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 200, height: 150), image: image)

        drag(view, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 140, y: 100))
        #expect(view.currentSelection == CGRect(x: 20, y: 20, width: 120, height: 80))

        drag(view, from: CGPoint(x: 80, y: 60), to: CGPoint(x: 90, y: 65))
        #expect(view.currentSelection == CGRect(x: 30, y: 25, width: 120, height: 80))

        var copied: Data?
        view.onCopy = { copied = $0 }
        key(view, code: 36, characters: "\r")
        let png = try #require(copied)
        let decoded = try #require(NSImage(data: png))
        #expect(decoded.size == NSSize(width: 120, height: 80))
    }

    @Test func reverseSelectionPreservesPixelsAtOneAndTwoTimesScale() throws {
        _ = NSApplication.shared
        for scale in [1, 2] {
            let image = try makeImage(width:200 * scale,height:150 * scale)
            let view = SelectionView(frame:NSRect(x:0,y:0,width:200,height:150),image:image)
            drag(view,from:CGPoint(x:140,y:100),to:CGPoint(x:20,y:20))
            #expect(view.currentSelection == CGRect(x:20,y:20,width:120,height:80))
            var copied: Data?
            view.onCopy = { copied = $0 }
            key(view,code:36,characters:"\r")
            let png = try #require(copied)
            let rep = try #require(NSBitmapImageRep(data:png))
            #expect(rep.pixelsWide == 120 * scale)
            #expect(rep.pixelsHigh == 80 * scale)
        }
    }

    @Test func optionACancelsTheActiveSelection() throws {
        _ = NSApplication.shared
        let image = try makeImage(width: 200, height: 150)
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 200, height: 150), image: image)
        drag(view, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 140, y: 100))
        var cancelled = false
        view.onCancel = { cancelled = true }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
                                                  timestamp: 0, windowNumber: 0, context: nil,
                                                  characters: "å", charactersIgnoringModifiers: "a",
                                                  isARepeat: false, keyCode: 0))
        view.keyDown(with: event)
        #expect(cancelled)
    }

    @Test func unhandledKeysAreIgnoredByTheSelectionView() throws {
        _ = NSApplication.shared
        let image = try makeImage(width: 200, height: 150)
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 200, height: 150), image: image)
        drag(view, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 140, y: 100))
        var cancelled = false
        view.onCancel = { cancelled = true }
        key(view, code: 7, characters: "x")
        #expect(!cancelled)
    }

    @Test func drawingDirectlyOnSelectionIsIncludedInConfirmCopy() throws {
        _ = NSApplication.shared
        let image = try makeImage(width: 240, height: 160)
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 240, height: 160), image: image)

        drag(view, from: CGPoint(x: 40, y: 30), to: CGPoint(x: 200, y: 130))
        view.selectTool(.rectangle)
        let canvas = try #require(view.currentCanvas)
        #expect(canvas.frame == view.currentSelection)

        drag(canvas, from: CGPoint(x: 70, y: 55), to: CGPoint(x: 160, y: 110))
        #expect(canvas.annotations.count == 1)

        var copied: Data?
        view.onCopy = { copied = $0 }
        canvas.onConfirm?()
        let png = try #require(copied)
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == 160)
        #expect(rep.pixelsHigh == 100)

        var redPixels = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.7, color.greenComponent < 0.4, color.blueComponent < 0.4 {
                    redPixels += 1
                }
            }
        }
        #expect(redPixels > 50)
    }


    private func drag(_ view: NSView, from start: CGPoint, to end: CGPoint) {
        let down = mouse(.leftMouseDown, at: start)
        let dragged = mouse(.leftMouseDragged, at: end)
        let up = mouse(.leftMouseUp, at: end)
        view.mouseDown(with: down)
        view.mouseDragged(with: dragged)
        view.mouseUp(with: up)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func key(_ view: NSView, code: UInt16, characters: String) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false,
                                     keyCode: code)!
        view.keyDown(with: event)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
