#!/usr/bin/env swift
import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/make-demo-library.swift <output-directory>\nAn explicit output directory is required. Existing files are never overwritten.\n", stderr)
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let scenes: [(String, CGFloat, CGFloat, CGFloat)] = [
    ("Morgenlicht", 0.08, 0.50, 0.94), ("Alpengipfel", 0.53, 0.42, 0.64),
    ("Abendsonne", 0.02, 0.67, 0.88), ("Küstennebel", 0.48, 0.28, 0.71),
    ("Blaue Stunde", 0.62, 0.51, 0.56), ("Wüstenwind", 0.10, 0.47, 0.80),
    ("Waldsee", 0.37, 0.33, 0.53), ("Nordlicht", 0.43, 0.52, 0.66),
    ("Lavendelfeld", 0.76, 0.31, 0.76), ("Herbsthügel", 0.07, 0.58, 0.78),
    ("Wintermorgen", 0.56, 0.14, 0.85), ("Goldene Stunde", 0.12, 0.63, 0.94)
]

var created = 0
for (index, scene) in scenes.enumerated() {
    let file = output.appendingPathComponent(String(format: "%02d-", index + 1) + scene.0 + ".jpg")
    guard !FileManager.default.fileExists(atPath: file.path) else {
        print("Skipped existing file: \(file.lastPathComponent)")
        continue
    }
    let portrait = index % 4 == 1
    let width = portrait ? 1000 : 1600
    let height = portrait ? 1500 : 1067
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Could not create demo image")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(width) / 1600, y: CGFloat(height) / 1067)
    let sky = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1600, height: 1067))
    let base = NSColor(calibratedHue: scene.1, saturation: scene.2, brightness: scene.3, alpha: 1)
    let light = NSColor(calibratedHue: scene.1, saturation: scene.2 * 0.35, brightness: min(1, scene.3 + 0.15), alpha: 1)
    NSGradient(starting: base, ending: light)!.draw(in: sky, angle: -90)
    NSColor(calibratedRed: 1, green: 0.91, blue: 0.70, alpha: 0.92).setFill()
    let sunX = CGFloat(250 + index * 137 % 1100)
    NSBezierPath(ovalIn: NSRect(x: sunX, y: 680, width: 112, height: 112)).fill()

    for layer in 0..<5 {
        let ridge = NSBezierPath()
        ridge.move(to: NSPoint(x: 0, y: 0))
        for step in 0...16 {
            let x = CGFloat(step * 100)
            let phase = CGFloat(index) * 0.71 + CGFloat(layer) * 1.4
            let wave = sin(CGFloat(step) * 0.63 + phase) * CGFloat(75 + layer * 8)
                + cos(CGFloat(step) * 0.31 + phase) * 35
            let y = CGFloat(580 - layer * 90) + wave
            ridge.line(to: NSPoint(x: x, y: y))
        }
        ridge.line(to: NSPoint(x: 1600, y: 0))
        ridge.close()
        NSColor(calibratedHue: scene.1, saturation: min(0.85, scene.2 + 0.13), brightness: max(0.12, scene.3 * CGFloat(0.77 - Double(layer) * 0.11)), alpha: 1).setFill()
        ridge.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
        fatalError("Could not encode demo image")
    }
    try jpeg.write(to: file, options: .withoutOverwriting)
    created += 1
}
print("Created \(created) synthetic images in \(output.path)")
