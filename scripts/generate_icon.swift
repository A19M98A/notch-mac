#!/usr/bin/env swift
import AppKit
import CoreGraphics

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

// Outer ambient drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 44, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
ctx.setFillColor(CGColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1.0))
ctx.addPath(squirclePath)
ctx.fillPath()
ctx.restoreGState()

// Clip inside squircle
ctx.saveGState()
ctx.addPath(squirclePath)
ctx.clip()

// 1. Deep Obsidian / Midnight Glass Gradient Background
let bgColors = [
    CGColor(red: 0.11, green: 0.15, blue: 0.24, alpha: 1.0),
    CGColor(red: 0.04, green: 0.05, blue: 0.10, alpha: 1.0),
    CGColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1.0)
] as CFArray
let bgLocs: [CGFloat] = [0.0, 0.55, 1.0]
if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocs) {
    ctx.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: masterSize / 2, y: iconRect.maxY),
        end: CGPoint(x: masterSize / 2, y: iconRect.minY),
        options: []
    )
}

// 2. Smooth Ambient Aurora Glow (startRadius: 0 + .drawsBeforeStartLocation — zero center artifact!)
let cyanGlowColors = [
    CGColor(red: 0.0, green: 0.84, blue: 1.0, alpha: 0.34),
    CGColor(red: 0.0, green: 0.84, blue: 1.0, alpha: 0.0)
] as CFArray
if let cyanRadial = CGGradient(colorsSpace: colorSpace, colors: cyanGlowColors, locations: [0.0, 1.0]) {
    ctx.drawRadialGradient(
        cyanRadial,
        startCenter: CGPoint(x: 330, y: 700),
        startRadius: 0,
        endCenter: CGPoint(x: 330, y: 700),
        endRadius: 430,
        options: [.drawsBeforeStartLocation]
    )
}

let purpleGlowColors = [
    CGColor(red: 0.54, green: 0.28, blue: 1.0, alpha: 0.30),
    CGColor(red: 0.54, green: 0.28, blue: 1.0, alpha: 0.0)
] as CFArray
if let purpleRadial = CGGradient(colorsSpace: colorSpace, colors: purpleGlowColors, locations: [0.0, 1.0]) {
    ctx.drawRadialGradient(
        purpleRadial,
        startCenter: CGPoint(x: 700, y: 300),
        startRadius: 0,
        endCenter: CGPoint(x: 700, y: 300),
        endRadius: 430,
        options: [.drawsBeforeStartLocation]
    )
}

// 3. Signature macOS Top Dynamic Notch Silhouette
let notchW: CGFloat = 430
let notchH: CGFloat = 132
let notchTopY = iconRect.maxY
let notchBottomY = notchTopY - notchH
let notchLeft = (masterSize - notchW) / 2
let notchRight = notchLeft + notchW
let earR: CGFloat = 28
let bottomR: CGFloat = 42

let notchPath = CGMutablePath()
notchPath.move(to: CGPoint(x: notchLeft - earR, y: notchTopY))
notchPath.addQuadCurve(to: CGPoint(x: notchLeft, y: notchTopY - earR), control: CGPoint(x: notchLeft, y: notchTopY))
notchPath.addLine(to: CGPoint(x: notchLeft, y: notchBottomY + bottomR))
notchPath.addQuadCurve(to: CGPoint(x: notchLeft + bottomR, y: notchBottomY), control: CGPoint(x: notchLeft, y: notchBottomY))
notchPath.addLine(to: CGPoint(x: notchRight - bottomR, y: notchBottomY))
notchPath.addQuadCurve(to: CGPoint(x: notchRight, y: notchBottomY + bottomR), control: CGPoint(x: notchRight, y: notchBottomY))
notchPath.addLine(to: CGPoint(x: notchRight, y: notchTopY - earR))
notchPath.addQuadCurve(to: CGPoint(x: notchRight + earR, y: notchTopY), control: CGPoint(x: notchRight, y: notchTopY))
notchPath.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.42))
ctx.setFillColor(CGColor(red: 0.01, green: 0.01, blue: 0.02, alpha: 0.98))
ctx.addPath(notchPath)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.setStrokeColor(CGColor(red: 0.25, green: 0.90, blue: 1.0, alpha: 0.65))
ctx.setLineWidth(4.5)
ctx.addPath(notchPath)
ctx.strokePath()
ctx.restoreGState()

// Status indicators inside top Notch
let dotY = notchBottomY + 52
ctx.setFillColor(CGColor(red: 0.18, green: 0.92, blue: 0.48, alpha: 1.0))
ctx.fillEllipse(in: CGRect(x: masterSize / 2 - 78, y: dotY - 9, width: 18, height: 18))

let pillRect = CGRect(x: masterSize / 2 - 34, y: dotY - 7, width: 68, height: 14)
ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.88))
ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: 7, cornerHeight: 7, transform: nil))
ctx.fillPath()

ctx.setFillColor(CGColor(red: 1.0, green: 0.62, blue: 0.15, alpha: 1.0))
ctx.fillEllipse(in: CGRect(x: masterSize / 2 + 60, y: dotY - 9, width: 18, height: 18))

// 4. Center Pulse Audio Waveform Bars
let barHeights: [CGFloat] = [120, 225, 340, 430, 340, 225, 120]
let barWidth: CGFloat = 44
let barSpacing: CGFloat = 30
let totalW = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * barSpacing
let startX = (masterSize - totalW) / 2
let centerY: CGFloat = 435

ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 38, color: CGColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.70))
for (i, h) in barHeights.enumerated() {
    let bx = startX + CGFloat(i) * (barWidth + barSpacing)
    let by = centerY - h / 2
    let r = CGRect(x: bx, y: by, width: barWidth, height: h)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
}
ctx.setFillColor(CGColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.35))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
for (i, h) in barHeights.enumerated() {
    let bx = startX + CGFloat(i) * (barWidth + barSpacing)
    let by = centerY - h / 2
    let r = CGRect(x: bx, y: by, width: barWidth, height: h)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
}
ctx.clip()

let waveColors = [
    CGColor(red: 0.25, green: 0.98, blue: 0.84, alpha: 1.0),
    CGColor(red: 0.05, green: 0.78, blue: 1.0, alpha: 1.0),
    CGColor(red: 0.38, green: 0.48, blue: 1.0, alpha: 1.0)
] as CFArray
if let waveGrad = CGGradient(colorsSpace: colorSpace, colors: waveColors, locations: [0.0, 0.5, 1.0]) {
    ctx.drawLinearGradient(
        waveGrad,
        start: CGPoint(x: startX, y: centerY + 220),
        end: CGPoint(x: startX + totalW, y: centerY - 220),
        options: []
    )
}
ctx.restoreGState()

// 5. Specular Glass Rim
ctx.addPath(squirclePath)
ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.22))
ctx.setLineWidth(6.0)
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

// Save 1024px preview PNG
try renderPNG(px: 1024).write(to: URL(fileURLWithPath: pngOutPath))

// Build native Apple ICNS container with all standard macOS Retina & 1x PNG chunks
let chunks: [(String, Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("ic11", 32),
    ("ic12", 64),
    ("ic07", 128),
    ("ic13", 256),
    ("ic08", 256),
    ("ic14", 512),
    ("ic09", 512),
    ("ic10", 1024)
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
print("Generated \(icnsOutPath) (\(icnsData.count) bytes)")
