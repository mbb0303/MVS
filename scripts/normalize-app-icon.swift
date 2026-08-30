#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: normalize-app-icon.swift INPUT.png OUTPUT.png\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("Could not read input PNG.\n", stderr)
    exit(1)
}

let width = image.width
let height = image.height
let bytesPerRow = width * 4
var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Could not create pixel context.\n", stderr)
    exit(1)
}
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

func alphaAt(x: Int, y: Int) -> UInt8 {
    pixels[y * bytesPerRow + x * 4 + 3]
}

let cornerAlpha = [
    alphaAt(x: 0, y: 0),
    alphaAt(x: width - 1, y: 0),
    alphaAt(x: 0, y: height - 1),
    alphaAt(x: width - 1, y: height - 1),
]
guard cornerAlpha.allSatisfy({ $0 == 0 }) else {
    fputs("Input corners are not transparent: \(cornerAlpha)\n", stderr)
    exit(1)
}

var minX = width
var minY = height
var maxX = -1
var maxY = -1
for y in 0..<height {
    for x in 0..<width where alphaAt(x: x, y: y) > 4 {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }
}
guard maxX >= minX, maxY >= minY else {
    fputs("Input contains no visible pixels.\n", stderr)
    exit(1)
}

let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
guard let cropped = image.cropping(to: cropRect) else {
    fputs("Could not crop visible icon bounds.\n", stderr)
    exit(1)
}

let canvasSize = 1024
let maximumMarkSize = 900.0
let scale = min(maximumMarkSize / Double(cropped.width), maximumMarkSize / Double(cropped.height))
let drawWidth = Double(cropped.width) * scale
let drawHeight = Double(cropped.height) * scale
let drawRect = CGRect(
    x: (Double(canvasSize) - drawWidth) / 2,
    y: (Double(canvasSize) - drawHeight) / 2,
    width: drawWidth,
    height: drawHeight
)

var outputPixels = [UInt8](repeating: 0, count: canvasSize * canvasSize * 4)
guard let outputContext = CGContext(
    data: &outputPixels,
    width: canvasSize,
    height: canvasSize,
    bitsPerComponent: 8,
    bytesPerRow: canvasSize * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Could not create output context.\n", stderr)
    exit(1)
}
outputContext.interpolationQuality = .high
outputContext.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
outputContext.draw(cropped, in: drawRect)
guard let outputImage = outputContext.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      ) else {
    fputs("Could not create output PNG.\n", stderr)
    exit(1)
}
CGImageDestinationAddImage(destination, outputImage, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("Could not write output PNG.\n", stderr)
    exit(1)
}

print("Normalized \(width)x\(height) RGBA icon to 1024x1024 with transparent corners.")
