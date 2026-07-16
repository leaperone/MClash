#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let repository = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let outputURL = repository.appending(path: "Sources/MClashApp/Resources/AppIcon.icns")
let iconsetURL = repository.appending(path: ".build/MClashAppIcon.iconset", directoryHint: .isDirectory)
let fileManager = FileManager.default

try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1_024),
]

for (name, pixels) in variants {
    try renderIcon(pixels: pixels, to: iconsetURL.appending(path: name))
}

let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", outputURL.path, iconsetURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    throw IconError.iconutilFailed(iconutil.terminationStatus)
}

print("Generated \(outputURL.path)")

private func renderIcon(pixels: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconError.contextCreationFailed
    }

    let scale = CGFloat(pixels) / 1_024
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    context.setFillColor(CGColor(red: 0.055, green: 0.22, blue: 0.46, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896), cornerWidth: 210, cornerHeight: 210, transform: nil))
    context.fillPath()

    context.setStrokeColor(CGColor(red: 0.32, green: 0.66, blue: 1, alpha: 0.72))
    context.setLineWidth(18)
    context.addPath(CGPath(roundedRect: CGRect(x: 91, y: 91, width: 842, height: 842), cornerWidth: 184, cornerHeight: 184, transform: nil))
    context.strokePath()

    let nodeColor = CGColor(red: 0.74, green: 0.9, blue: 1, alpha: 1)
    context.setStrokeColor(nodeColor)
    context.setLineWidth(34)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 278, y: 690))
    context.addLine(to: CGPoint(x: 746, y: 690))
    context.addLine(to: CGPoint(x: 512, y: 285))
    context.closePath()
    context.strokePath()

    for point in [CGPoint(x: 278, y: 690), CGPoint(x: 746, y: 690), CGPoint(x: 512, y: 285)] {
        context.setFillColor(CGColor(red: 0.055, green: 0.22, blue: 0.46, alpha: 1))
        context.fillEllipse(in: CGRect(x: point.x - 62, y: point.y - 62, width: 124, height: 124))
        context.setStrokeColor(nodeColor)
        context.setLineWidth(30)
        context.strokeEllipse(in: CGRect(x: point.x - 47, y: point.y - 47, width: 94, height: 94))
    }

    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: 512, y: 710))
    shield.addCurve(
        to: CGPoint(x: 690, y: 625),
        control1: CGPoint(x: 575, y: 690),
        control2: CGPoint(x: 635, y: 665)
    )
    shield.addLine(to: CGPoint(x: 676, y: 472))
    shield.addCurve(
        to: CGPoint(x: 512, y: 340),
        control1: CGPoint(x: 666, y: 405),
        control2: CGPoint(x: 602, y: 362)
    )
    shield.addCurve(
        to: CGPoint(x: 348, y: 472),
        control1: CGPoint(x: 422, y: 362),
        control2: CGPoint(x: 358, y: 405)
    )
    shield.addLine(to: CGPoint(x: 334, y: 625))
    shield.addCurve(
        to: CGPoint(x: 512, y: 710),
        control1: CGPoint(x: 389, y: 665),
        control2: CGPoint(x: 449, y: 690)
    )
    shield.closeSubpath()

    context.setFillColor(CGColor(red: 0.92, green: 0.97, blue: 1, alpha: 1))
    context.addPath(shield)
    context.fillPath()

    context.setStrokeColor(CGColor(red: 0.055, green: 0.22, blue: 0.46, alpha: 1))
    context.setLineWidth(42)
    context.setLineJoin(.round)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 425, y: 465))
    context.addLine(to: CGPoint(x: 425, y: 590))
    context.addLine(to: CGPoint(x: 512, y: 510))
    context.addLine(to: CGPoint(x: 599, y: 590))
    context.addLine(to: CGPoint(x: 599, y: 465))
    context.strokePath()

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL,
              UTType.png.identifier as CFString,
              1,
              nil
          ) else {
        throw IconError.imageCreationFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError.imageWriteFailed
    }
}

private enum IconError: Error {
    case contextCreationFailed
    case imageCreationFailed
    case imageWriteFailed
    case iconutilFailed(Int32)
}
