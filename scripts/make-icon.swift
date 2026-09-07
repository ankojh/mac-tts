import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let ratio = CGFloat(pixels) / 1024
        let transform = NSAffineTransform()
        transform.scale(by: ratio)
        transform.concat()
        NSColor(calibratedRed: 0.105, green: 0.12, blue: 0.115, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 205, yRadius: 205).fill()
        NSColor(calibratedRed: 0.56, green: 0.86, blue: 0.71, alpha: 1).setFill()
        for (index, height) in [190.0, 360, 510, 310, 160].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 256 + Double(index) * 104, y: (1024 - height) / 2, width: 70, height: height), xRadius: 35, yRadius: 35).fill()
        }
        image.unlockFocus()
        let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let png = representation.representation(using: .png, properties: [:])!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try png.write(to: directory.appendingPathComponent(name))
    }
}
