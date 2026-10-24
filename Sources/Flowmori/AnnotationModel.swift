import AppKit

enum AnnotationTool: Int, CaseIterable {
    case select, rectangle, arrow, text, pen
    var title: String {
        switch self {
        case .select: "选择"
        case .rectangle: "矩形"
        case .arrow: "箭头"
        case .text: "文字"
        case .pen: "画笔"
        }
    }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .pen: "scribble"
        }
    }
}

struct Annotation: Identifiable {
    enum Kind { case rectangle, arrow, text, pen }
    var id = UUID()
    var kind: Kind
    var color: NSColor
    var lineWidth: CGFloat
    var rect: CGRect = .zero
    var start: CGPoint = .zero
    var end: CGPoint = .zero
    var points: [CGPoint] = []
    var text: String = ""
    var fontSize: CGFloat = 22
    var textWidth: CGFloat = 260

    var textHeight: CGFloat {
        guard kind == .text else { return 0 }
        let font = NSFont.systemFont(ofSize: fontSize)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: max(20, textWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(font.pointSize * 1.4, ceil(bounds.height) + 4)
    }

    var bounds: CGRect {
        switch kind {
        case .rectangle: return rect.standardized
        case .arrow:
            let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                             width: abs(end.x - start.x), height: abs(end.y - start.y))
            return box.insetBy(dx: -max(8, lineWidth * 3), dy: -max(8, lineWidth * 3))
        case .text: return CGRect(x: rect.minX, y: rect.minY, width: max(20, textWidth), height: textHeight)
        case .pen:
            guard let first = points.first else { return .zero }
            var box = CGRect(origin: first, size: .zero)
            for point in points.dropFirst() {
                box = box.union(CGRect(origin: point, size: .zero))
            }
            return box.insetBy(dx: -max(6, lineWidth * 2), dy: -max(6, lineWidth * 2))
        }
    }

    var handles: [CGPoint] {
        switch kind {
        case .rectangle:
            let r = rect.standardized
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        case .arrow: return [start, end]
        default: return []
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .rectangle: return rect.standardized.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .arrow: return AnnotationGeometry.distance(point, toSegment: start, end) <= tolerance
        case .text: return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .pen:
            guard points.count > 1 else { return points.first.map { AnnotationGeometry.distance(point, $0) <= tolerance } ?? false }
            for index in 1..<points.count where AnnotationGeometry.distance(point, toSegment: points[index - 1], points[index]) <= tolerance { return true }
            return false
        }
    }

    mutating func move(by delta: CGPoint, inside size: CGSize) {
        let box = bounds
        var dx = delta.x, dy = delta.y
        if box.minX + dx < 0 { dx = -box.minX }
        if box.minY + dy < 0 { dy = -box.minY }
        if box.maxX + dx > size.width { dx = size.width - box.maxX }
        if box.maxY + dy > size.height { dy = size.height - box.maxY }
        switch kind {
        case .rectangle, .text: rect.origin.x += dx; rect.origin.y += dy
        case .arrow: start.x += dx; start.y += dy; end.x += dx; end.y += dy
        case .pen: points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        }
    }

    mutating func resize(handle: Int, to point: CGPoint, inside size: CGSize) {
        let clamped = CGPoint(x: min(max(0, point.x), size.width), y: min(max(0, point.y), size.height))
        switch kind {
        case .rectangle:
            let old = rect.standardized
            var minX = old.minX, maxX = old.maxX, minY = old.minY, maxY = old.maxY
            switch handle {
            case 0: minX = clamped.x; minY = clamped.y
            case 1: maxX = clamped.x; minY = clamped.y
            case 2: maxX = clamped.x; maxY = clamped.y
            default: minX = clamped.x; maxY = clamped.y
            }
            if abs(maxX - minX) < 4 { if handle == 0 || handle == 3 { minX = maxX - 4 } else { maxX = minX + 4 } }
            if abs(maxY - minY) < 4 { if handle == 0 || handle == 1 { minY = maxY - 4 } else { maxY = minY + 4 } }
            rect = CGRect(x: min(max(0, minX), size.width), y: min(max(0, minY), size.height),
                          width: maxX - minX, height: maxY - minY).intersection(CGRect(origin: .zero, size: size))
        case .arrow:
            if handle == 0 { start = clamped } else { end = clamped }
        default: break
        }
    }

    static func rectangle(from start: CGPoint, to end: CGPoint, color: NSColor, lineWidth: CGFloat) -> Annotation {
        Annotation(kind: .rectangle, color: color, lineWidth: lineWidth,
                   rect: CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                width: abs(end.x - start.x), height: abs(end.y - start.y)))
    }
    static func arrow(from start: CGPoint, to end: CGPoint, color: NSColor, lineWidth: CGFloat) -> Annotation {
        Annotation(kind: .arrow, color: color, lineWidth: lineWidth, start: start, end: end)
    }
    static func pen(points: [CGPoint], color: NSColor, lineWidth: CGFloat) -> Annotation {
        Annotation(kind: .pen, color: color, lineWidth: lineWidth, points: points)
    }
    static func text(_ text: String, at point: CGPoint, width: CGFloat, fontSize: CGFloat, color: NSColor) -> Annotation {
        var annotation = Annotation(kind: .text, color: color, lineWidth: 0,
                                    rect: CGRect(x: point.x, y: point.y, width: width, height: 0))
        annotation.text = text; annotation.textWidth = width; annotation.fontSize = fontSize
        return annotation
    }
}

enum AnnotationGeometry {
    static func distance(_ point: CGPoint, _ other: CGPoint) -> CGFloat {
        hypot(point.x - other.x, point.y - other.y)
    }
    static func distance(_ point: CGPoint, toSegment start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = dx * dx + dy * dy
        guard length > 0.0001 else { return distance(point, start) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length))
        return distance(point, CGPoint(x: start.x + t * dx, y: start.y + t * dy))
    }
}

enum AnnotationRenderer {
    static func viewPoint(_ point: CGPoint, imageRect: CGRect, scale: CGFloat) -> CGPoint {
        CGPoint(x: imageRect.minX + point.x * scale, y: imageRect.minY + point.y * scale)
    }
    static func viewRect(_ rect: CGRect, imageRect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: imageRect.minX + rect.minX * scale, y: imageRect.minY + rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale)
    }
    static func draw(_ annotation: Annotation, imageRect: CGRect, scale: CGFloat) {
        let line = max(1, annotation.lineWidth * scale)
        annotation.color.setStroke()
        switch annotation.kind {
        case .rectangle:
            let path = NSBezierPath(rect: viewRect(annotation.rect.standardized, imageRect: imageRect, scale: scale))
            path.lineWidth = line; path.stroke()
        case .arrow:
            let a = viewPoint(annotation.start, imageRect: imageRect, scale: scale)
            let b = viewPoint(annotation.end, imageRect: imageRect, scale: scale)
            let path = NSBezierPath(); path.lineWidth = line; path.lineCapStyle = .round
            path.move(to: a); path.line(to: b)
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(9, line * 3.2)
            for offset in [CGFloat.pi * 0.78, -CGFloat.pi * 0.78] {
                let p = CGPoint(x: b.x + cos(angle + offset) * head, y: b.y + sin(angle + offset) * head)
                path.move(to: b); path.line(to: p)
            }
            path.stroke()
        case .pen:
            guard let first = annotation.points.first else { return }
            let path = NSBezierPath(); path.lineWidth = line; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: viewPoint(first, imageRect: imageRect, scale: scale))
            for point in annotation.points.dropFirst() { path.line(to: viewPoint(point, imageRect: imageRect, scale: scale)) }
            if annotation.points.count == 1 { path.line(to: path.currentPoint) }
            path.stroke()
        case .text:
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(6, annotation.fontSize * scale)),
                .foregroundColor: annotation.color,
                .paragraphStyle: {
                    let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping; return style
                }()
            ]
            let rect = viewRect(CGRect(x: annotation.rect.minX, y: annotation.rect.minY,
                                       width: annotation.textWidth, height: annotation.textHeight),
                                imageRect: imageRect, scale: scale)
            (annotation.text as NSString).draw(in: rect, withAttributes: attributes)
        }
    }
}

enum AnnotationExporter {
    static func png(image: CGImage, annotations: [Annotation]) -> Data? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: CGFloat(width), height: CGFloat(height))
        let export = AnnotationExportView(frame: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
                                          image: image, annotations: annotations)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        export.cacheDisplay(in: export.bounds, to: rep)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

final class AnnotationExportView: NSView {
    let image: CGImage
    let annotations: [Annotation]
    init(frame: NSRect, image: CGImage, annotations: [Annotation]) {
        self.image = image; self.annotations = annotations; super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        for annotation in annotations { AnnotationRenderer.draw(annotation, imageRect: bounds, scale: 1) }
    }
}
