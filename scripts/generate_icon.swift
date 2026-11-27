#!/usr/bin/env swift
import AppKit
import CoreGraphics
import CoreText

let masterSize: CGFloat = 1024
let pngOutPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/AppIcon-1024.png"
let icnsOutPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Resources/AppIcon.icns"

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(masterSize),
    height: Int(masterSize),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Failed to create CGContext")
}

ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

let pad: CGFloat = 100
let iconRect = CGRect(x: pad, y: pad, width: masterSize - pad * 2, height: masterSize - pad * 2)
let cornerRadius: CGFloat = 185
let squirclePath = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

// Subtle ambient drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.48))
ctx.setFillColor(CGColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1.0))
ctx.addPath(squirclePath)
ctx.fillPath()
ctx.restoreGState()

// Clip inside squircle
ctx.saveGState()
ctx.addPath(squirclePath)
ctx.clip()

// Minimal matte obsidian gradient background
let bgColors = [
    CGColor(red: 0.13, green: 0.14, blue: 0.18, alpha: 1.0),
    CGColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1.0)
] as CFArray
if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
    ctx.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: masterSize / 2, y: iconRect.maxY),
        end: CGPoint(x: masterSize / 2, y: iconRect.minY),
        options: []
    )
}

// Single minimal math symbol (∞) centered cleanly
let symbol = "∞" as CFString
let baseFont = NSFont.systemFont(ofSize: 580, weight: .light)
let attrs: [NSAttributedString.Key: Any] = [
    .font: baseFont,
    .foregroundColor: NSColor.white
]
let attrStr = NSAttributedString(string: symbol as String, attributes: attrs)
let line = CTLineCreateWithAttributedString(attrStr)
let glyphBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])

// Center optically inside iconRect
let drawX = iconRect.midX - glyphBounds.midX
let drawY = iconRect.midY - glyphBounds.midY

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.35))
ctx.textPosition = CGPoint(x: drawX, y: drawY)
CTLineDraw(line, ctx)
ctx.restoreGState()

// Hairline 1px-equivalent glass border
ctx.addPath(squirclePath)
ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.14))
ctx.setLineWidth(4.0)
ctx.strokePath()
ctx.restoreGState()

guard let masterImage = ctx.makeImage() else {
    fatalError("Failed to render master icon")
}

func renderPNG(px: Int) -> Data {
    guard let c = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Failed to create \(px)x\(px) context")
    }
    c.interpolationQuality = .high
    c.draw(masterImage, in: CGRect(x: 0, y: 0, width: px, height: px))
    guard let img = c.makeImage() else { fatalError("Failed to make \(px)px image") }
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: px, height: px)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode \(px)px PNG")
    }
    return data
}

try renderPNG(px: 1024).write(to: URL(fileURLWithPath: pngOutPath))

let chunks: [(String, Int)] = [
    ("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64),
    ("ic07", 128), ("ic13", 256), ("ic08", 256), ("ic14", 512),
    ("ic09", 512), ("ic10", 1024)
]

var bodyData = Data()
for (ostype, px) in chunks {
    let png = renderPNG(px: px)
    bodyData.append(ostype.data(using: .ascii)!)
    var lenBE = UInt32(8 + png.count).bigEndian
    bodyData.append(Data(bytes: &lenBE, count: 4))
    bodyData.append(png)
}

var icnsData = Data()
icnsData.append("icns".data(using: .ascii)!)
var totalLenBE = UInt32(8 + bodyData.count).bigEndian
icnsData.append(Data(bytes: &totalLenBE, count: 4))
icnsData.append(bodyData)

let icnsURL = URL(fileURLWithPath: icnsOutPath)
try FileManager.default.createDirectory(at: icnsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try icnsData.write(to: icnsURL)
print("Generated minimal math icon \(icnsOutPath) (\(icnsData.count) bytes)")
