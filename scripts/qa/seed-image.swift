import AppKit

// Known pixels for pin/resize/save acceptance. No screen capture or user files.
let output = URL(fileURLWithPath:CommandLine.arguments[1])
let context = CGContext(data:nil,width:960,height:540,bitsPerComponent:8,bytesPerRow:0,
    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
for (rect,color) in [
    (CGRect(x:0,y:0,width:480,height:270),NSColor.systemBlue),
    (CGRect(x:480,y:0,width:480,height:270),NSColor.systemGreen),
    (CGRect(x:0,y:270,width:480,height:270),NSColor.systemOrange),
    (CGRect(x:480,y:270,width:480,height:270),NSColor.systemPurple)
] { context.setFillColor(color.cgColor); context.fill(rect) }
context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(4)
context.stroke(CGRect(x:4,y:4,width:952,height:532))
context.move(to:CGPoint(x:0,y:0)); context.addLine(to:CGPoint(x:960,y:540)); context.strokePath()
let image = context.makeImage()!
let png = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!
try png.write(to:output)
NSPasteboard.general.clearContents(); NSPasteboard.general.setData(png,forType:.png)
print("Seeded known 960x540 PNG fixture")
