#!/usr/bin/env swift
import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift make-app-icon.swift <output.iconset>\n", stderr)
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
}

func drawIcon() {
    let background = NSBezierPath(roundedRect: NSRect(x: 68, y: 68, width: 888, height: 888), xRadius: 198, yRadius: 198)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0.10, 0.13, 0.17).setFill()
    background.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0.18, 0.23, 0.28), ending: color(0.06, 0.08, 0.11))!.draw(in: background, angle: -70)
    NSColor.white.withAlphaComponent(0.10).setStroke()
    background.lineWidth = 3
    background.stroke()

    NSGraphicsContext.saveGraphicsState()
    var transform = AffineTransform(translationByX: 512, byY: 510)
    transform.rotate(byDegrees: -11)
    transform.translate(x: -512, y: -510)
    (transform as NSAffineTransform).concat()
    let back = NSBezierPath(roundedRect: NSRect(x: 213, y: 247, width: 592, height: 501), xRadius: 37, yRadius: 37)
    color(0.35, 0.48, 0.52).setFill()
    back.fill()
    NSGraphicsContext.restoreGraphicsState()

    let frame = NSBezierPath(roundedRect: NSRect(x: 215, y: 248, width: 592, height: 501), xRadius: 40, yRadius: 40)
    NSGraphicsContext.saveGraphicsState()
    let cardShadow = NSShadow()
    cardShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    cardShadow.shadowBlurRadius = 27
    cardShadow.shadowOffset = NSSize(width: 0, height: -15)
    cardShadow.set()
    color(0.91, 0.93, 0.92).setFill()
    frame.fill()
    NSGraphicsContext.restoreGraphicsState()

    let image = NSBezierPath(roundedRect: NSRect(x: 244, y: 300, width: 534, height: 420), xRadius: 17, yRadius: 17)
    NSGraphicsContext.saveGraphicsState()
    image.addClip()
    NSGradient(starting: color(0.16, 0.43, 0.48), ending: color(0.60, 0.80, 0.77))!.draw(in: image, angle: 90)
    color(0.99, 0.76, 0.41).setFill()
    NSBezierPath(ovalIn: NSRect(x: 583, y: 559, width: 94, height: 94)).fill()
    let mountain = NSBezierPath()
    mountain.move(to: NSPoint(x: 200, y: 300))
    mountain.line(to: NSPoint(x: 420, y: 591))
    mountain.line(to: NSPoint(x: 570, y: 415))
    mountain.line(to: NSPoint(x: 674, y: 518))
    mountain.line(to: NSPoint(x: 830, y: 304))
    mountain.close()
    color(0.13, 0.29, 0.34).setFill()
    mountain.fill()
    let foreground = NSBezierPath()
    foreground.move(to: NSPoint(x: 180, y: 300))
    foreground.curve(to: NSPoint(x: 826, y: 380), controlPoint1: NSPoint(x: 347, y: 540), controlPoint2: NSPoint(x: 588, y: 223))
    foreground.line(to: NSPoint(x: 826, y: 250))
    foreground.line(to: NSPoint(x: 180, y: 250))
    foreground.close()
    color(0.08, 0.19, 0.23).setFill()
    foreground.fill()
    NSGraphicsContext.restoreGraphicsState()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Could not create icon bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode icon bitmap")
        }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"), options: .atomic)
    }
}
