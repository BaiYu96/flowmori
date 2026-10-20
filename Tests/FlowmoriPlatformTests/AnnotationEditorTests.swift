import AppKit
import Testing
@testable import Flowmori

@MainActor @Suite struct AnnotationEditorTests {
    @Test func rectangleNormalizesReverseDragAndClampsMovementAndResize() {
        var annotation = Annotation.rectangle(from: CGPoint(x: 100, y: 70), to: CGPoint(x: 20, y: 10),
                                              color: .systemRed, lineWidth: 4)
        #expect(annotation.rect == CGRect(x: 20, y: 10, width: 80, height: 60))
        annotation.move(by: CGPoint(x: 100, y: 100), inside: CGSize(width: 120, height: 80))
        #expect(annotation.rect == CGRect(x: 40, y: 20, width: 80, height: 60))
        annotation.resize(handle: 2, to: CGPoint(x: 200, y: 200), inside: CGSize(width: 120, height: 80))
        #expect(annotation.rect.maxX == 120)
        #expect(annotation.rect.maxY == 80)
    }

    @Test func arrowAndPenHitTestingUsesStrokeDistance() {
        let arrow = Annotation.arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 10), color: .black, lineWidth: 2)
        #expect(arrow.hitTest(CGPoint(x: 50, y: 13), tolerance: 4))
        #expect(!arrow.hitTest(CGPoint(x: 50, y: 30), tolerance: 4))
        let pen = Annotation.pen(points: [CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 20), CGPoint(x: 50, y: 60)],
                                 color: .black, lineWidth: 2)
        #expect(pen.hitTest(CGPoint(x: 50, y: 40), tolerance: 3))
    }

    @Test func exportHasOriginalPixelDimensionsAndDrawsAnnotations() throws {
        let width = 120, height = 80
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let annotation = Annotation.rectangle(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 90, y: 55),
                                              color: .black, lineWidth: 4)
        let view = AnnotationExportView(frame: NSRect(x: 0, y: 0, width: width, height: height),
                                        image: image, annotations: [annotation])
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        view.cacheDisplay(in: view.bounds, to: rep)
        var darkPixels = 0
        for x in 0..<width {
            for y in 0..<height {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent < 0.5 { darkPixels += 1 }
            }
        }
        #expect(darkPixels > 100)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let decoded = try #require(NSImage(data: png))
        #expect(decoded.size == NSSize(width: width, height: height))
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
    }

    @Test func textAnnotationIsRenderedIntoTheExport() throws {
        let width = 200, height = 80
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let annotation = Annotation.text("中文标注", at: CGPoint(x: 12, y: 12), width: 170,
                                         fontSize: 20, color: .systemRed)
        let view = AnnotationExportView(frame: NSRect(x: 0, y: 0, width: width, height: height),
                                        image: image, annotations: [annotation])
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        view.cacheDisplay(in: view.bounds, to: rep)
        var colored = 0
        for x in 0..<width {
            for y in 0..<height {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   abs(color.redComponent - 1) > 0.05 || abs(color.greenComponent - 1) > 0.05 || abs(color.blueComponent - 1) > 0.05 {
                    colored += 1
                }
            }
        }
        #expect(colored > 20)
    }

    @Test func textAnnotationComputesMultilineBounds() {
        let annotation = Annotation.text("第一行\n第二行", at: CGPoint(x: 10, y: 10), width: 160,
                                         fontSize: 20, color: .systemRed)
        #expect(annotation.bounds.width == 160)
        #expect(annotation.bounds.height > 20)
        #expect(annotation.bounds.minX == 10)
    }
}
