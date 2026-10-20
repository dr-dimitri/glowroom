#!/usr/bin/env swift
import AppKit
import ImageIO

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift make-app-icon.swift <source.png> <output.iconset>\n", stderr)
    exit(2)
}

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fputs("Could not read app icon: \(source.path)\n", stderr)
    exit(1)
}
guard image.width == image.height, image.width >= 1024 else {
    fputs("App icon must be square and at least 1024 pixels wide.\n", stderr)
    exit(1)
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

// Decode once and resize in one worker: these ten small outputs do not justify
// another worker pool alongside the parallel application compilation.
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Could not create icon graphics context")
        }
        let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        context.clear(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let resized = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: resized).representation(using: .png, properties: [:]) else {
            fatalError("Could not encode icon bitmap")
        }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"), options: .atomic)
    }
}
