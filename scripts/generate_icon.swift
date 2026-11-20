#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Generates a 1024x1024 macOS squircle icon for MacSweep in Deep Ocean style.
guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate_icon.swift <output-1024.png>\n", stderr)
    exit(1)
}
let outputPath = CommandLine.arguments[1]
let size: CGFloat = 1024

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Failed to create CGContext\n", stderr)
    exit(1)
}

ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

// Outer macOS icon canvas margin (~10% padding for standard Big Sur+ squircle)
let inset: CGFloat = 96
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let cornerRadius: CGFloat = rect.width * 0.225

func roundedPath(_ r: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Drop shadow
ctx.saveGState()
ctx.setShadow(
    offset: CGSize(width: 0, height: -20),
    blur: 42,
    color: CGColor(red: 0.01, green: 0.05, blue: 0.12, alpha: 0.55)
)
ctx.addPath(roundedPath(rect, radius: cornerRadius))
ctx.setFillColor(CGColor(red: 0.04, green: 0.11, blue: 0.22, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// Clip to squircle
ctx.saveGState()
ctx.addPath(roundedPath(rect, radius: cornerRadius))
ctx.clip()

// Deep ocean background gradient
let bgColors = [
    CGColor(red: 0.05, green: 0.15, blue: 0.30, alpha: 1),
    CGColor(red: 0.03, green: 0.09, blue: 0.19, alpha: 1),
    CGColor(red: 0.02, green: 0.06, blue: 0.14, alpha: 1),
] as CFArray
if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0]) {
    ctx.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )
}

// Radial top-right cyan-blue glow
let glowColors = [
    CGColor(red: 0.18, green: 0.62, blue: 1.0, alpha: 0.42),
    CGColor(red: 0.10, green: 0.40, blue: 0.85, alpha: 0.12),
    CGColor(red: 0.05, green: 0.20, blue: 0.50, alpha: 0.0),
] as CFArray
if let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0, 0.45, 1]) {
    let center = CGPoint(x: size * 0.62, y: size * 0.68)
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 10, endCenter: center, endRadius: 420, options: [])
}

// Subtle inner top highlight border
ctx.addPath(roundedPath(rect.insetBy(dx: 4, dy: 4), radius: cornerRadius - 4))
ctx.setStrokeColor(CGColor(red: 0.48, green: 0.78, blue: 1.0, alpha: 0.28))
ctx.setLineWidth(6)
ctx.strokePath()

// Layered stylized folder + sparkle motif in clean geometric form
let folderBack = CGRect(x: 256, y: 292, width: 512, height: 344)
let tabPath = CGMutablePath()
tabPath.move(to: CGPoint(x: folderBack.minX, y: folderBack.minY + 46))
tabPath.addLine(to: CGPoint(x: folderBack.minX, y: folderBack.maxY - 12))
tabPath.addQuadCurve(to: CGPoint(x: folderBack.minX + 36, y: folderBack.maxY + 24), control: CGPoint(x: folderBack.minX, y: folderBack.maxY + 24))
tabPath.addLine(to: CGPoint(x: folderBack.minX + 188, y: folderBack.maxY + 24))
tabPath.addQuadCurve(to: CGPoint(x: folderBack.minX + 234, y: folderBack.maxY - 8), control: CGPoint(x: folderBack.minX + 216, y: folderBack.maxY + 24))
tabPath.addLine(to: CGPoint(x: folderBack.maxX - 36, y: folderBack.maxY - 8))
tabPath.addQuadCurve(to: CGPoint(x: folderBack.maxX, y: folderBack.maxY - 44), control: CGPoint(x: folderBack.maxX, y: folderBack.maxY - 8))
tabPath.addLine(to: CGPoint(x: folderBack.maxX, y: folderBack.minY + 46))
tabPath.addQuadCurve(to: CGPoint(x: folderBack.maxX - 46, y: folderBack.minY), control: CGPoint(x: folderBack.maxX, y: folderBack.minY))
tabPath.addLine(to: CGPoint(x: folderBack.minX + 46, y: folderBack.minY))
tabPath.addQuadCurve(to: CGPoint(x: folderBack.minX, y: folderBack.minY + 46), control: CGPoint(x: folderBack.minX, y: folderBack.minY))
tabPath.closeSubpath()

ctx.saveGState()
ctx.addPath(tabPath)
ctx.clip()
let backFolderColors = [
    CGColor(red: 0.14, green: 0.44, blue: 0.78, alpha: 1),
    CGColor(red: 0.08, green: 0.25, blue: 0.50, alpha: 1),
] as CFArray
if let fGrad = CGGradient(colorsSpace: colorSpace, colors: backFolderColors, locations: [0, 1]) {
    ctx.drawLinearGradient(fGrad, start: CGPoint(x: 256, y: 660), end: CGPoint(x: 768, y: 292), options: [])
}
ctx.restoreGState()

// Front frosted translucent blue panel
let folderFront = CGRect(x: 256, y: 274, width: 512, height: 290)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(red: 0, green: 0.05, blue: 0.14, alpha: 0.45))
ctx.addPath(roundedPath(folderFront, radius: 44))
ctx.clip()
let frontColors = [
    CGColor(red: 0.36, green: 0.78, blue: 1.0, alpha: 0.96),
    CGColor(red: 0.15, green: 0.53, blue: 0.95, alpha: 0.98),
    CGColor(red: 0.09, green: 0.36, blue: 0.78, alpha: 1.0),
] as CFArray
if let ffGrad = CGGradient(colorsSpace: colorSpace, colors: frontColors, locations: [0, 0.55, 1]) {
    ctx.drawLinearGradient(ffGrad, start: CGPoint(x: 280, y: 564), end: CGPoint(x: 740, y: 274), options: [])
}
ctx.restoreGState()

// Crisp glass top edge on front folder
ctx.addPath(roundedPath(folderFront.insetBy(dx: 2, dy: 2), radius: 42))
ctx.setStrokeColor(CGColor(red: 0.82, green: 0.95, blue: 1.0, alpha: 0.42))
ctx.setLineWidth(4)
ctx.strokePath()

// Four-point sparkle star (cleanliness emblem) in center of front panel
func drawSparkle(center: CGPoint, outer: CGFloat, inner: CGFloat, alpha: CGFloat) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: center.x, y: center.y + outer))
    p.addQuadCurve(to: CGPoint(x: center.x + outer, y: center.y), control: CGPoint(x: center.x + inner, y: center.y + inner))
    p.addQuadCurve(to: CGPoint(x: center.x, y: center.y - outer), control: CGPoint(x: center.x + inner, y: center.y - inner))
    p.addQuadCurve(to: CGPoint(x: center.x - outer, y: center.y), control: CGPoint(x: center.x - inner, y: center.y - inner))
    p.addQuadCurve(to: CGPoint(x: center.x, y: center.y + outer), control: CGPoint(x: center.x - inner, y: center.y + inner))
    p.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: CGColor(red: 0.75, green: 0.95, blue: 1.0, alpha: 0.65))
    ctx.addPath(p)
    ctx.setFillColor(CGColor(red: 0.96, green: 0.99, blue: 1.0, alpha: alpha))
    ctx.fillPath()
    ctx.restoreGState()
}

drawSparkle(center: CGPoint(x: 512, y: 420), outer: 92, inner: 16, alpha: 0.96)
drawSparkle(center: CGPoint(x: 684, y: 696), outer: 48, inner: 9, alpha: 0.92)
drawSparkle(center: CGPoint(x: 744, y: 616), outer: 24, inner: 5, alpha: 0.78)
drawSparkle(center: CGPoint(x: 368, y: 718), outer: 30, inner: 6, alpha: 0.70)

ctx.restoreGState()

guard let cgImage = ctx.makeImage() else {
    fputs("Failed to make image\n", stderr)
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}
let url = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
try pngData.write(to: url)
print("Generated icon PNG at \(outputPath)")
