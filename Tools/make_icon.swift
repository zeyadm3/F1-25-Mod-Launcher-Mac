import AppKit

// Draws the 1024×1024 app icon: red body, checkered stripe, white paint brush.
guard CommandLine.arguments.count > 1,
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: 1024, height: 1024)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 22
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(colors: [NSColor(srgbRed: 0.95, green: 0.20, blue: 0.22, alpha: 1),
                    NSColor(srgbRed: 0.55, green: 0.04, blue: 0.10, alpha: 1)])!.draw(in: body, angle: -90)

let square: CGFloat = 824 / 14
for row in 0..<2 {
    for column in 0..<14 {
        let color = (row + column) % 2 == 0 ? NSColor.white : NSColor(white: 0.08, alpha: 1)
        color.setFill()
        NSRect(x: body.minX + CGFloat(column) * square, y: body.minY + 150 + CGFloat(row) * square,
               width: square, height: square).fill()
    }
}

let config = NSImage.SymbolConfiguration(pointSize: 330, weight: .bold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let brush = NSImage(systemSymbolName: "paintbrush.pointed.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let size = brush.size
    let top = body.maxY - 70
    let bottom = body.minY + 150 + 2 * square + 40
    brush.draw(in: NSRect(x: body.midX - size.width / 2, y: (top + bottom) / 2 - size.height / 2,
                          width: size.width, height: size.height))
}
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
