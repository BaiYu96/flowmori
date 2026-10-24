import AppKit
import ImageIO

guard CommandLine.arguments.count >= 3 else {
    fputs("usage: make-icon.swift <iconset> <source.png>\n", stderr)
    exit(2)
}
let destination = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let sourceURL = URL(fileURLWithPath:CommandLine.arguments[2])
try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL,nil),
      let image = CGImageSourceCreateImageAtIndex(source,0,nil) else {
    fputs("cannot read icon source: \(sourceURL.path)\n", stderr)
    exit(2)
}
func png(_ pixels:Int) throws -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data:nil,width:pixels,height:pixels,bitsPerComponent:8,
                                  bytesPerRow:0,space:space,
                                  bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain:"FlowmoriIcon",code:1)
    }
    context.interpolationQuality = .high
    context.draw(image,in:CGRect(x:0,y:0,width:pixels,height:pixels))
    guard let output = context.makeImage() else { throw NSError(domain:"FlowmoriIcon",code:2) }
    let rep = NSBitmapImageRep(cgImage:output)
    guard let data = rep.representation(using:.png,properties:[:]) else { throw NSError(domain:"FlowmoriIcon",code:3) }
    return data
}
for size in [16,32,128,256,512] {
    try png(size).write(to:destination.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(size*2).write(to:destination.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
