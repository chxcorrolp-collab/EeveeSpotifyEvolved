import AppKit
import Foundation

let root = URL(fileURLWithPath: "Assets.xcassets", isDirectory: true)
let folder = root.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let bounds = NSRect(x: 0, y: 0, width: 1024, height: 1024)
NSGradient(starting: NSColor(srgbRed: 0.05, green: 0.07, blue: 0.10, alpha: 1), ending: NSColor(srgbRed: 0.11, green: 0.24, blue: 0.20, alpha: 1))!.draw(in: bounds, angle: 45)
NSColor(srgbRed: 0.635, green: 0.969, blue: 0.675, alpha: 1).setFill()
for (x, height) in [(288.0,260.0),(400,420),(512,580),(624,420),(736,260)] {
    NSBezierPath(roundedRect: NSRect(x: x-35, y: 512-height/2, width: 70, height: height), xRadius: 35, yRadius: 35).fill()
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("Sonora.png"))
let contents = """
{"images":[{"filename":"Sonora.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
"""
try contents.write(to: folder.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try "{\"info\":{\"author\":\"xcode\",\"version\":1}}".write(to: root.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
