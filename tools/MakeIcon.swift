import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let size = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let rect = NSRect(x: size*0.07, y: size*0.07, width: size*0.86, height: size*0.86)
    let path = NSBezierPath(roundedRect: rect, xRadius: size*0.19, yRadius: size*0.19)
    NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.53, blue: 0.95, alpha: 1), ending: NSColor(calibratedRed: 0.06, green: 0.28, blue: 0.72, alpha: 1))!.draw(in: path, angle: -90)
    let symbol = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: nil)!
    let config = NSImage.SymbolConfiguration(pointSize: size*0.40, weight: .regular)
    let colored = symbol.withSymbolConfiguration(config)!
    colored.isTemplate = true
    NSColor.white.set()
    let boxRect = NSRect(x: size*0.23, y: size*0.36, width: size*0.54, height: size*0.47)
    colored.draw(in: boxRect)
    let text = "ZIP" as NSString
    let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.boldSystemFont(ofSize: size*0.17), .foregroundColor:NSColor.white]
    let textSize = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: (size-textSize.width)/2, y: size*0.19), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
}
