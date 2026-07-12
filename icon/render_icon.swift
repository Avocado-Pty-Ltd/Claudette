// Standalone Swift script that renders the Claudette app icon to
// `icon/claudette_1024.png`. Run with:
//
//     swift icon/render_icon.swift
//
// The design: a woman in silhouette with long flowing hair, seated at a
// warm-glowing computer screen. Warm amber light spills from the screen and
// picks out her profile — same palette as the app's accent orange (0xC96442).

import AppKit
import CoreGraphics
import Foundation

// MARK: - Colour palette

extension NSColor {
    static let bgOuter    = NSColor(srgbRed: 0.055, green: 0.043, blue: 0.075, alpha: 1)
    static let bgInner    = NSColor(srgbRed: 0.100, green: 0.060, blue: 0.120, alpha: 1)
    static let ambient    = NSColor(srgbRed: 0.788, green: 0.392, blue: 0.259, alpha: 1)  // 0xC96442
    static let ambientHot = NSColor(srgbRed: 0.980, green: 0.688, blue: 0.365, alpha: 1)  // warm highlight
    static let screenHot  = NSColor(srgbRed: 1.000, green: 0.870, blue: 0.720, alpha: 1)  // glass hot spot
    static let personDark = NSColor(srgbRed: 0.070, green: 0.045, blue: 0.055, alpha: 1)
    static let rim        = NSColor(srgbRed: 0.980, green: 0.560, blue: 0.290, alpha: 1)
}

// MARK: - Convenience shading helpers

func addRadialGradient(in ctx: CGContext, colors: [NSColor], locations: [CGFloat],
                       start: CGPoint, startR: CGFloat,
                       end: CGPoint, endR: CGFloat) {
    let space = CGColorSpaceCreateDeviceRGB()
    let cgColors = colors.map { $0.cgColor } as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: locations)!
    ctx.drawRadialGradient(gradient, startCenter: start, startRadius: startR,
                           endCenter: end, endRadius: endR,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// MARK: - Icon renderer

let size: CGFloat = 1024
let W = Int(size)
let H = Int(size)

guard let ctx = CGContext(
    data: nil,
    width: W, height: H,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("failed to create bitmap context\n", stderr)
    exit(1)
}

// macOS Big-Sur-style rounded-square mask. The system further masks icons but
// this gives it the correct visual shape at every rendered size.
let cornerRadius: CGFloat = size * 0.225
let iconRect = CGRect(x: 0, y: 0, width: size, height: size)
let iconPath = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
ctx.saveGState()
ctx.addPath(iconPath)
ctx.clip()

// ─── 1. Backdrop ───────────────────────────────────────────────────────────────
// Radial gradient — deep purple/indigo core fading to nearly-black at the edges.
addRadialGradient(
    in: ctx,
    colors: [NSColor.bgInner, NSColor.bgOuter, NSColor(srgbRed: 0.005, green: 0.005, blue: 0.02, alpha: 1)],
    locations: [0.0, 0.55, 1.0],
    start: CGPoint(x: size * 0.42, y: size * 0.55),
    startR: 0,
    end: CGPoint(x: size * 0.42, y: size * 0.55),
    endR: size * 0.85
)

// ─── 2. Warm glow from the screen ─────────────────────────────────────────────
// Big soft amber halo that spills out from where the screen sits, giving the
// silhouette its rim-lighting.
let screenCentre = CGPoint(x: size * 0.68, y: size * 0.48)
addRadialGradient(
    in: ctx,
    colors: [
        NSColor.ambientHot.withAlphaComponent(0.55),
        NSColor.ambient.withAlphaComponent(0.28),
        NSColor.ambient.withAlphaComponent(0.0)
    ],
    locations: [0.0, 0.35, 1.0],
    start: screenCentre, startR: size * 0.02,
    end:   screenCentre, endR:   size * 0.68
)

// ─── 3. The desk / floor plane (very subtle) ──────────────────────────────────
// A soft horizontal glow along the bottom to ground the composition.
addRadialGradient(
    in: ctx,
    colors: [
        NSColor.ambient.withAlphaComponent(0.25),
        NSColor.ambient.withAlphaComponent(0.0)
    ],
    locations: [0.0, 1.0],
    start: CGPoint(x: size * 0.5, y: size * 0.06), startR: 0,
    end:   CGPoint(x: size * 0.5, y: size * 0.06), endR: size * 0.55
)

// ─── 4. The computer screen ───────────────────────────────────────────────────
// A softly-rounded rectangle standing on a thin base ("stand") — this is what
// throws the warm light onto the woman.
func drawScreen() {
    let screenW = size * 0.36
    let screenH = size * 0.24
    let cx = size * 0.72
    let cy = size * 0.50
    let rect = CGRect(x: cx - screenW / 2, y: cy - screenH / 2,
                      width: screenW, height: screenH)
    let radius = size * 0.020

    // Glass surface — hot centre, cooler edges.
    ctx.saveGState()
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    addRadialGradient(
        in: ctx,
        colors: [
            NSColor.screenHot,
            NSColor.ambientHot,
            NSColor.ambient
        ],
        locations: [0.0, 0.55, 1.0],
        start: CGPoint(x: cx - screenW * 0.15, y: cy + screenH * 0.15), startR: 0,
        end:   CGPoint(x: cx, y: cy), endR: screenW * 0.75
    )
    ctx.restoreGState()

    // Thin bezel outline.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(NSColor.ambient.withAlphaComponent(0.55).cgColor)
    ctx.setLineWidth(size * 0.005)
    ctx.strokePath()
    ctx.restoreGState()

    // Reflective highlight — a soft diagonal streak on the glass.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let streak = CGMutablePath()
    streak.move(to: CGPoint(x: rect.minX - 40, y: rect.maxY + 40))
    streak.addLine(to: CGPoint(x: rect.minX + rect.width * 0.55, y: rect.maxY + 40))
    streak.addLine(to: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.minY - 40))
    streak.addLine(to: CGPoint(x: rect.minX - 40, y: rect.minY - 40))
    streak.closeSubpath()
    ctx.addPath(streak)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Stand — small trapezoid + base.
    let standTop = CGPoint(x: cx, y: rect.minY)
    let standBottomHalf = size * 0.04
    let standBottomY = rect.minY - size * 0.055
    let stand = CGMutablePath()
    stand.move(to: CGPoint(x: standTop.x - size * 0.012, y: standTop.y))
    stand.addLine(to: CGPoint(x: standTop.x + size * 0.012, y: standTop.y))
    stand.addLine(to: CGPoint(x: standTop.x + standBottomHalf, y: standBottomY))
    stand.addLine(to: CGPoint(x: standTop.x - standBottomHalf, y: standBottomY))
    stand.closeSubpath()
    ctx.addPath(stand)
    ctx.setFillColor(NSColor(srgbRed: 0.14, green: 0.09, blue: 0.09, alpha: 1).cgColor)
    ctx.fillPath()

    // Base bar.
    let baseRect = CGRect(x: cx - size * 0.11, y: standBottomY - size * 0.014,
                          width: size * 0.22, height: size * 0.014)
    let basePath = CGPath(roundedRect: baseRect, cornerWidth: size * 0.007, cornerHeight: size * 0.007, transform: nil)
    ctx.addPath(basePath)
    ctx.setFillColor(NSColor(srgbRed: 0.12, green: 0.08, blue: 0.08, alpha: 1).cgColor)
    ctx.fillPath()
}
drawScreen()

// ─── 5. The woman's silhouette ────────────────────────────────────────────────
// Composed from cubic-Bezier curves so the outline reads as flowing hair rather
// than a stiff polygon. She's viewed in profile from the left, facing right
// toward the screen, with hair cascading down her back.
func drawWoman() {
    let path = CGMutablePath()

    // Reference point — the crown of the head. Positioned so the woman occupies
    // roughly the left third of the icon with plenty of room for the screen.
    let crownX = size * 0.30
    let crownY = size * 0.78
    let s: CGFloat = size / 1024.0

    // Trace clockwise around the whole silhouette starting at the crown.
    path.move(to: CGPoint(x: crownX, y: crownY))

    // Forehead — a soft curve down to just above the brow line.
    path.addCurve(
        to: CGPoint(x: crownX + 96 * s, y: crownY - 88 * s),
        control1: CGPoint(x: crownX + 80 * s, y: crownY),
        control2: CGPoint(x: crownX + 100 * s, y: crownY - 48 * s)
    )
    // Brow → nose bridge (subtle inward dip so there's a hint of eye socket).
    path.addCurve(
        to: CGPoint(x: crownX + 88 * s, y: crownY - 116 * s),
        control1: CGPoint(x: crownX + 96 * s, y: crownY - 100 * s),
        control2: CGPoint(x: crownX + 88 * s, y: crownY - 108 * s)
    )
    // Bridge → tip of nose.
    path.addCurve(
        to: CGPoint(x: crownX + 130 * s, y: crownY - 158 * s),
        control1: CGPoint(x: crownX + 106 * s, y: crownY - 128 * s),
        control2: CGPoint(x: crownX + 128 * s, y: crownY - 142 * s)
    )
    // Nose tip → upper lip.
    path.addCurve(
        to: CGPoint(x: crownX + 92 * s, y: crownY - 184 * s),
        control1: CGPoint(x: crownX + 120 * s, y: crownY - 170 * s),
        control2: CGPoint(x: crownX + 100 * s, y: crownY - 178 * s)
    )
    // Lips → chin.
    path.addCurve(
        to: CGPoint(x: crownX + 84 * s, y: crownY - 246 * s),
        control1: CGPoint(x: crownX + 92 * s, y: crownY - 208 * s),
        control2: CGPoint(x: crownX + 96 * s, y: crownY - 228 * s)
    )
    // Chin → jaw underside.
    path.addCurve(
        to: CGPoint(x: crownX + 42 * s, y: crownY - 280 * s),
        control1: CGPoint(x: crownX + 78 * s, y: crownY - 264 * s),
        control2: CGPoint(x: crownX + 60 * s, y: crownY - 276 * s)
    )
    // Neck front (a small concave scoop for the throat).
    path.addCurve(
        to: CGPoint(x: crownX + 44 * s, y: crownY - 360 * s),
        control1: CGPoint(x: crownX + 30 * s, y: crownY - 306 * s),
        control2: CGPoint(x: crownX + 32 * s, y: crownY - 330 * s)
    )
    // Collarbone slope → shoulder.
    path.addCurve(
        to: CGPoint(x: crownX + 210 * s, y: crownY - 400 * s),
        control1: CGPoint(x: crownX + 90 * s, y: crownY - 372 * s),
        control2: CGPoint(x: crownX + 160 * s, y: crownY - 384 * s)
    )
    // Shoulder → upper arm curving down and out toward keyboard.
    path.addCurve(
        to: CGPoint(x: crownX + 306 * s, y: crownY - 528 * s),
        control1: CGPoint(x: crownX + 258 * s, y: crownY - 430 * s),
        control2: CGPoint(x: crownX + 300 * s, y: crownY - 480 * s)
    )
    // Forearm → back to torso side (the arm curves back in — she's reaching
    // to the keyboard, not fully extended).
    path.addCurve(
        to: CGPoint(x: crownX + 168 * s, y: crownY - 610 * s),
        control1: CGPoint(x: crownX + 300 * s, y: crownY - 580 * s),
        control2: CGPoint(x: crownX + 240 * s, y: crownY - 606 * s)
    )
    // Underside of arm → torso side.
    path.addCurve(
        to: CGPoint(x: crownX + 88 * s, y: crownY - 660 * s),
        control1: CGPoint(x: crownX + 140 * s, y: crownY - 634 * s),
        control2: CGPoint(x: crownX + 110 * s, y: crownY - 656 * s)
    )
    // Waist → cut off at bottom of icon.
    path.addLine(to: CGPoint(x: crownX + 40 * s, y: crownY - 720 * s))
    path.addLine(to: CGPoint(x: crownX - 340 * s, y: crownY - 720 * s))
    // Left side of body / bottom of long hair.
    path.addCurve(
        to: CGPoint(x: crownX - 340 * s, y: crownY - 440 * s),
        control1: CGPoint(x: crownX - 360 * s, y: crownY - 640 * s),
        control2: CGPoint(x: crownX - 360 * s, y: crownY - 540 * s)
    )
    // Big flowing hair curve up the back — the S-shape that gives her the
    // "long flowing hair" silhouette.
    path.addCurve(
        to: CGPoint(x: crownX - 260 * s, y: crownY - 220 * s),
        control1: CGPoint(x: crownX - 320 * s, y: crownY - 360 * s),
        control2: CGPoint(x: crownX - 300 * s, y: crownY - 280 * s)
    )
    // Hair rising to back of head.
    path.addCurve(
        to: CGPoint(x: crownX - 170 * s, y: crownY - 50 * s),
        control1: CGPoint(x: crownX - 240 * s, y: crownY - 160 * s),
        control2: CGPoint(x: crownX - 210 * s, y: crownY - 100 * s)
    )
    // Back of head → crown (top curve).
    path.addCurve(
        to: CGPoint(x: crownX, y: crownY),
        control1: CGPoint(x: crownX - 150 * s, y: crownY - 20 * s),
        control2: CGPoint(x: crownX - 70 * s, y: crownY + 8 * s)
    )
    path.closeSubpath()

    // Fill — a very dark warm charcoal so the silhouette reads pure black at
    // small sizes but has warmth up close.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setFillColor(NSColor.personDark.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Rim light — draw the silhouette again but offset toward the screen and
    // clipped to a thin band along the front of the face/body. Uses a warm
    // amber to simulate the screen light picking out the edge.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(NSColor.rim.withAlphaComponent(0.85).cgColor)
    ctx.setLineWidth(size * 0.006)
    ctx.setLineJoin(.round)
    // Only stroke the RIGHT side (facing the screen) by clipping.
    let rimClip = CGRect(x: crownX - 10, y: 0, width: size, height: size)
    ctx.clip(to: rimClip)
    ctx.strokePath()
    ctx.restoreGState()

    // Hair strand highlights — a couple of soft curved lines catching the light.
    ctx.saveGState()
    ctx.setStrokeColor(NSColor.rim.withAlphaComponent(0.28).cgColor)
    ctx.setLineWidth(size * 0.0035)
    ctx.setLineCap(.round)
    let strand1 = CGMutablePath()
    strand1.move(to: CGPoint(x: crownX - 90 * s, y: crownY - 40 * s))
    strand1.addCurve(
        to: CGPoint(x: crownX - 210 * s, y: crownY - 400 * s),
        control1: CGPoint(x: crownX - 150 * s, y: crownY - 160 * s),
        control2: CGPoint(x: crownX - 220 * s, y: crownY - 260 * s)
    )
    ctx.addPath(strand1)
    ctx.strokePath()

    let strand2 = CGMutablePath()
    strand2.move(to: CGPoint(x: crownX - 40 * s, y: crownY - 40 * s))
    strand2.addCurve(
        to: CGPoint(x: crownX - 140 * s, y: crownY - 500 * s),
        control1: CGPoint(x: crownX - 90 * s, y: crownY - 180 * s),
        control2: CGPoint(x: crownX - 170 * s, y: crownY - 340 * s)
    )
    ctx.addPath(strand2)
    ctx.strokePath()
    ctx.restoreGState()
}
drawWoman()

// ─── 6. Foreground vignette ──────────────────────────────────────────────────
// A soft dark ring at the corners of the squircle so the composition doesn't
// feel evenly-lit — pushes the eye toward the woman and the screen.
addRadialGradient(
    in: ctx,
    colors: [
        NSColor.black.withAlphaComponent(0.0),
        NSColor.black.withAlphaComponent(0.0),
        NSColor.black.withAlphaComponent(0.55)
    ],
    locations: [0.0, 0.55, 1.0],
    start: CGPoint(x: size * 0.5, y: size * 0.5), startR: 0,
    end:   CGPoint(x: size * 0.5, y: size * 0.5), endR: size * 0.7
)

ctx.restoreGState()

// ─── Export ───────────────────────────────────────────────────────────────────

guard let cgImage = ctx.makeImage() else {
    fputs("failed to make image\n", stderr); exit(1)
}
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to encode png\n", stderr); exit(1)
}

let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("icon")
let outURL = outDir.appendingPathComponent("claudette_1024.png")

// Explicit do/catch so failures surface the underlying error instead of a
// generic "errors thrown from here are not handled" (top-level `try` compiles
// in a Swift script but is easy to break by adding a wrapping function later)
// or being silently swallowed by `try?` on the directory creation.
do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try pngData.write(to: outURL)
    print("wrote \(outURL.path)")
} catch {
    fputs("failed to write icon: \(error.localizedDescription)\n", stderr)
    exit(1)
}
