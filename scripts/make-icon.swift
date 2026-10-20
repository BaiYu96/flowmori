import AppKit
let destination = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
func drawIcon(_ pixels:Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:pixels*4,bitsPerPixel:32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
    let background = NSBezierPath(roundedRect:NSRect(x:40,y:40,width:944,height:944),xRadius:208,yRadius:208)
    NSGradient(starting:NSColor(srgbRed:0.07,green:0.45,blue:0.56,alpha:1),ending:NSColor(srgbRed:0.06,green:0.18,blue:0.32,alpha:1))!.draw(in:background,angle:-65)
    for (index,offset) in [(-90.0,-95.0),(-10.0,-10.0),(70.0,75.0)].enumerated() {
        let rect = NSRect(x:245+offset.0,y:270+offset.1,width:430,height:345)
        NSColor.white.withAlphaComponent([0.24,0.52,1.0][index]).setFill()
        NSBezierPath(roundedRect:rect,xRadius:45,yRadius:45).fill()
        if index == 2 {
            NSColor(srgbRed:0.06,green:0.38,blue:0.49,alpha:1).setFill()
            NSBezierPath(roundedRect:rect.insetBy(dx:34,dy:34),xRadius:18,yRadius:18).fill()
        }
    }
    NSColor(srgbRed:1,green:0.75,blue:0.31,alpha:1).setFill()
    NSBezierPath(ovalIn:NSRect(x:690,y:245,width:106,height:106)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using:.png,properties:[:])!
}
for size in [16,32,128,256,512] {
    try drawIcon(size).write(to:destination.appendingPathComponent("icon_\(size)x\(size).png"))
    try drawIcon(size*2).write(to:destination.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
