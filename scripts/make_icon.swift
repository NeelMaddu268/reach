// Draws the app icon: a hand pointing at a glowing target with sonar rings, on deep blue.
// Usage: swift scripts/make_icon.swift Reach/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit

let side = 1024
// RGB with no alpha (App Store icons must be opaque). AppKit can't draw into an alpha-less NSBitmapImageRep,
// so draw through a Core Graphics context instead.
let cg = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
let full = NSRect(x: 0, y: 0, width: side, height: side)

NSGradient(starting: NSColor(red: 0.05, green: 0.16, blue: 0.42, alpha: 1),
           ending: NSColor(red: 0.01, green: 0.04, blue: 0.14, alpha: 1))!.draw(in: full, angle: -60)

// Target, upper right, with sonar rings.
let target = NSPoint(x: 660, y: 640)
for (radius, alpha) in [(300.0, 0.10), (225.0, 0.18), (150.0, 0.30)] {
    let ring = NSBezierPath(ovalIn: NSRect(x: target.x - radius, y: target.y - radius, width: radius * 2, height: radius * 2))
    ring.lineWidth = 22
    NSColor(white: 1, alpha: alpha).setStroke()
    ring.stroke()
}
NSColor(red: 1, green: 0.80, blue: 0.20, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: target.x - 70, y: target.y - 70, width: 140, height: 140)).fill()

// Hand, lower left, pointing up and right at the target.
let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let hand = NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let size = hand.size
    let transform = NSAffineTransform()
    transform.translateX(by: 330, yBy: 300)
    transform.rotate(byDegrees: -45)  // index finger toward the target
    transform.concat()
    hand.draw(in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
}
NSGraphicsContext.restoreGraphicsState()
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let destination = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, cg.makeImage()!, nil)
CGImageDestinationFinalize(destination)
