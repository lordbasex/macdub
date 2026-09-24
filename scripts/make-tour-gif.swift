#!/usr/bin/env swift
// Builds the README's animated tour from screenshots (ImageIO only, no dependencies):
//
//   swift scripts/make-tour-gif.swift images/macdub-tour.gif 1200 750 2.2 shot1.png shot2.png …
//
// Every frame is width × height: each screenshot is scaled to fit and centred on a dark
// background, so the window captures and the smaller Settings / menu bar ones mix well.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count > 5, let width = Int(args[2]), let height = Int(args[3]), let delay = Double(args[4]) else {
    print("usage: make-tour-gif.swift out.gif width height seconds-per-frame shots…")
    exit(2)
}
let output = URL(fileURLWithPath: args[1])
let shots = args.dropFirst(5).map { URL(fileURLWithPath: $0) }

guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, shots.count, nil) else {
    print("cannot write \(output.path)")
    exit(1)
}
CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary

let space = CGColorSpaceCreateDeviceRGB()
for shot in shots {
    guard let source = CGImageSourceCreateWithURL(shot as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        print("skipping \(shot.lastPathComponent)")
        continue
    }
    context.setFillColor(CGColor(red: 0.09, green: 0.07, blue: 0.14, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
    let w = Double(image.width) * scale, h = Double(image.height) * scale
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
    if let frame = context.makeImage() { CGImageDestinationAddImage(destination, frame, frameProperties) }
}
guard CGImageDestinationFinalize(destination) else {
    print("failed to write \(output.path)")
    exit(1)
}
print("✔ \(output.path) (\(shots.count) frames)")
