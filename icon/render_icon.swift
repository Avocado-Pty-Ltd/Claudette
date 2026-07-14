// Renders the Claudette "Ember" app icon to `icon/claudette_1024.png`.
// Run with:
//
//     swift icon/render_icon.swift
//
// Design: a distilled solar-system tableau. Deep-purple void, three tiny
// stars, one warm central orb (the agent), a tilted orbit ring, and a small
// amethyst sub-agent companion sphere. Pixel-spec ported from the Claude
// Design bundle `Claudette Explorations.dc.html` → element `#1a Ember`.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Design tokens (from Claudette Explorations.dc.html § 1a Ember)
//
// The design was drawn at 264×264. Everything below is expressed as a
// fraction of that so the icon composites correctly at any size.
struct EmberSpec {
    // Background — deep purple void with an off-centre core.
    let bgGradientCentre = CGPoint(x: 0.42, y: 0.58)
    let bgColorCore     = NSColor(srgbRed: 0x1A/255, green: 0x0F/255, blue: 0x1E/255, alpha: 1)
    let bgColorMid      = NSColor(srgbRed: 0x0E/255, green: 0x08/255, blue: 0x13/255, alpha: 1)
    let bgColorEdge     = NSColor(srgbRed: 0x05/255, green: 0x04/255, blue: 0x0A/255, alpha: 1)

    // Ambient amber wash from the top-centre where the orb sits.
    let ambientCentre   = CGPoint(x: 0.50, y: 0.44)
    let ambientHot      = NSColor(srgbRed: 227/255, green: 138/255, blue: 63/255, alpha: 0.32) // #E38A3F α
    let ambientMid      = NSColor(srgbRed: 201/255, green: 100/255, blue: 66/255, alpha: 0.10) // #C96442 α
    let ambientEdge     = NSColor.clear
    let ambientFalloff  = 0.70   // stop where alpha hits zero

    // Three stars: two cool, one warm. Positions from the design HTML,
    // measured in the 264 canvas from top-left corner.
    let stars: [(x: Double, y: Double, r: Double, color: NSColor, opacity: Double)] = [
        (x: 18.0 + 2, y: 36.0 + 2, r: 2.0,
         color: NSColor(srgbRed: 1.0, green: 0.910, blue: 0.760, alpha: 1), opacity: 0.70), // #FFE8C2
        (x: 264.0 - 34 - 1.5, y: 64.0 + 1.5, r: 1.5,
         color: .white, opacity: 0.50),
        (x: 52.0 + 1.5, y: 264.0 - 44 - 1.5, r: 1.5,
         color: .white, opacity: 0.40)
    ]

    // Central orb (radial gradient inside a 118px sphere at 50%, 44%).
    let orbCentre         = CGPoint(x: 0.50, y: 0.44)
    let orbDiameter       = 118.0 // in the 264 canvas
    // Radial gradient origin sits 33% right and 28% down INSIDE the orb.
    let orbHighlightOffset = CGPoint(x: 0.33 - 0.5, y: 0.28 - 0.5) // relative to orb centre, in orb diameters
    let orbCoreHighlight  = NSColor(srgbRed: 0xFF/255, green: 0xE9/255, blue: 0xCB/255, alpha: 1) // #FFE9CB
    let orbBody           = NSColor(srgbRed: 0xF5/255, green: 0xB3/255, blue: 0x7A/255, alpha: 1) // #F5B37A @26%
    let orbAccent         = NSColor(srgbRed: 0xC9/255, green: 0x64/255, blue: 0x42/255, alpha: 1) // #C96442 @58%
    let orbDeep           = NSColor(srgbRed: 0x5A/255, green: 0x24/255, blue: 0x17/255, alpha: 1) // #5A2417 @88%
    // Outer amber glow behind the orb.
    let orbHalo           = NSColor(srgbRed: 227/255, green: 138/255, blue: 63/255, alpha: 0.45) // #E38A3F α
    // Interior shadow bottom-right (design's `inset -10px -14px 26px rgba(0,0,0,.45)`).
    let orbShadowOffset   = CGPoint(x: -10.0 / 118.0, y: -14.0 / 118.0)
    let orbShadowColor    = NSColor.black.withAlphaComponent(0.45)

    // Tilted orbit ellipse: 230×76 at 50%, 44% rotated −16°.
    let orbitWidth        = 230.0
    let orbitHeight       = 76.0
    let orbitCentre       = CGPoint(x: 0.50, y: 0.44)
    let orbitTiltRadians  = -16.0 * .pi / 180.0
    // Rear half — soft, thin.
    let orbitRearColor    = NSColor(srgbRed: 246/255, green: 194/255, blue: 154/255, alpha: 0.35)
    let orbitStroke       = 1.4
    // Front half — brighter arc that overlays the orb, sold as depth.
    let orbitFrontColor   = NSColor(srgbRed: 246/255, green: 194/255, blue: 154/255, alpha: 0.55)
    // In design: clip-path:inset(38px 0 0 0) hides the top 38px of the ellipse.
    let orbitFrontClipTop = 38.0

    // Sub-agent (amethyst) — 12px sphere offset from orb centre.
    // Design: left: calc(50% + 96px); top: calc(44% + 28px).
    let subOffset         = CGPoint(x: 96.0, y: 28.0)  // in 264 units, screen coords
    let subDiameter       = 12.0
    let subHighlight      = NSColor(srgbRed: 0xED/255, green: 0xE0/255, blue: 0xFF/255, alpha: 1) // #EDE0FF
    let subBody           = NSColor(srgbRed: 0xA6/255, green: 0x80/255, blue: 0xE5/255, alpha: 1) // #A680E5 @60%
    let subDeep           = NSColor(srgbRed: 0x4A/255, green: 0x34/255, blue: 0x68/255, alpha: 1) // #4A3468
    let subGlow           = NSColor(srgbRed: 166/255, green: 128/255, blue: 229/255, alpha: 0.80)
    let subGlowRadius     = 12.0

    // Sheen highlight — subtle diagonal top glow across the tile.
    let sheenAlpha        = 0.07
    let sheenFalloff      = 0.38  // fade to transparent at 38% down
}

// MARK: - Rendering

let size: CGFloat = 1024
let designCanvas: CGFloat = 264
/// Everything in the spec is quoted in the 264 canvas, so we scale by this.
let scale = size / designCanvas

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
    fputs("failed to create bitmap context\n", stderr); exit(1)
}

// CoreGraphics has origin bottom-left; the design spec uses top-left. Flip
// the coordinate system so we can transcribe positions directly.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

let spec = EmberSpec()

// Squircle mask — 22.35% corner radius matches Apple's macOS icon geometry.
let cornerRadius = size * (59.0 / designCanvas)
let iconPath = CGPath(
    roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
    cornerWidth: cornerRadius, cornerHeight: cornerRadius,
    transform: nil
)
ctx.saveGState()
ctx.addPath(iconPath)
ctx.clip()

// Helper — draw a radial gradient anchored inside the canvas.
func radial(centre: CGPoint, startR: CGFloat, endR: CGFloat, stops: [(CGFloat, NSColor)]) {
    let space = CGColorSpaceCreateDeviceRGB()
    let colors = stops.map { $0.1.cgColor } as CFArray
    let locations = stops.map { $0.0 }
    guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: locations) else { return }
    ctx.drawRadialGradient(
        gradient,
        startCenter: centre, startRadius: startR,
        endCenter: centre, endRadius: endR,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
}

// ─── 1. Deep-purple background ──────────────────────────────────────────────
// Radial gradient with the core down-and-left of centre so the composition
// has weight where the sub-agent sits.
radial(
    centre: CGPoint(x: size * spec.bgGradientCentre.x, y: size * spec.bgGradientCentre.y),
    startR: 0,
    endR: size * 0.75,
    stops: [
        (0.00, spec.bgColorCore),
        (0.55, spec.bgColorMid),
        (1.00, spec.bgColorEdge)
    ]
)

// ─── 2. Ambient amber wash ─────────────────────────────────────────────────
// Soft halo from the orb; this is what makes the icon "glow" at a small size.
radial(
    centre: CGPoint(x: size * spec.ambientCentre.x, y: size * spec.ambientCentre.y),
    startR: 0,
    endR: size * spec.ambientFalloff,
    stops: [
        (0.00, spec.ambientHot),
        (0.42, spec.ambientMid),
        (1.00, spec.ambientEdge)
    ]
)

// ─── 3. Stars (three) ──────────────────────────────────────────────────────
for star in spec.stars {
    // Convert the design-unit coords (Double) into CGFloat explicitly so this
    // block is portable to 32-bit builds where CGFloat is Float rather than
    // Double. The apparent equivalence on 64-bit Darwin is a coincidence of
    // the SDK, not a language guarantee.
    let cx = CGFloat(star.x) * scale
    let cy = CGFloat(star.y) * scale
    let r  = CGFloat(star.r) * scale
    let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
    ctx.setFillColor(star.color.withAlphaComponent(CGFloat(star.opacity)).cgColor)
    ctx.fillEllipse(in: rect)
}

// Utility — draw a rotated ellipse stroke, optionally clipped so only its
// lower half shows (used for the "front-of-orbit" brighter arc).
func drawOrbit(clippedFrontOnly: Bool, color: NSColor, strokeWidth: CGFloat) {
    let cx = size * spec.orbitCentre.x
    let cy = size * spec.orbitCentre.y
    let w = CGFloat(spec.orbitWidth) * scale
    let h = CGFloat(spec.orbitHeight) * scale

    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy)
    ctx.rotate(by: CGFloat(spec.orbitTiltRadians))
    if clippedFrontOnly {
        // clip-path:inset(38px 0 0 0) → the top 38 design-units are hidden.
        // In our translated + rotated space we mask everything above the line
        // y = -h/2 + 38.
        let clipTop = -h / 2 + CGFloat(spec.orbitFrontClipTop) * scale
        ctx.clip(to: CGRect(x: -w, y: clipTop, width: w * 2, height: h))
    }
    let ellipseRect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(CGFloat(strokeWidth) * scale)
    ctx.setLineCap(.round)
    ctx.strokeEllipse(in: ellipseRect)
    ctx.restoreGState()
}

// ─── 4. Rear orbit ring ────────────────────────────────────────────────────
drawOrbit(clippedFrontOnly: false, color: spec.orbitRearColor, strokeWidth: spec.orbitStroke)

// ─── 5. Central orb ────────────────────────────────────────────────────────
let orbCx = size * spec.orbCentre.x
let orbCy = size * spec.orbCentre.y
let orbR = CGFloat(spec.orbDiameter) * scale / 2

// Halo — a big soft gradient behind the orb.
radial(
    centre: CGPoint(x: orbCx, y: orbCy),
    startR: orbR * 0.55,
    endR: orbR * 3.1,
    stops: [
        (0.00, spec.orbHalo),
        (1.00, NSColor.clear)
    ]
)

// Orb body — clip to a circle and paint the four-stop radial gradient
// centred at (33%, 28%) inside the sphere for the highlight.
ctx.saveGState()
let orbRect = CGRect(x: orbCx - orbR, y: orbCy - orbR, width: orbR * 2, height: orbR * 2)
ctx.addPath(CGPath(ellipseIn: orbRect, transform: nil))
ctx.clip()

let orbHighlightCentre = CGPoint(
    x: orbCx + CGFloat(spec.orbHighlightOffset.x) * orbR * 2,
    y: orbCy + CGFloat(spec.orbHighlightOffset.y) * orbR * 2
)
radial(
    centre: orbHighlightCentre,
    startR: 0,
    endR: orbR * 1.4,
    stops: [
        (0.00, spec.orbCoreHighlight),
        (0.26, spec.orbBody),
        (0.58, spec.orbAccent),
        (0.88, spec.orbDeep)
    ]
)

// Inner shadow bottom-right — mimics the CSS `inset -10 -14 26 rgba(0,0,0,.45)`.
let shadowCentre = CGPoint(
    x: orbCx + CGFloat(spec.orbShadowOffset.x) * orbR * 2,
    y: orbCy + CGFloat(spec.orbShadowOffset.y) * orbR * 2
)
radial(
    centre: shadowCentre,
    startR: orbR * 0.55,
    endR: orbR * 1.15,
    stops: [
        (0.00, NSColor.clear),
        (1.00, spec.orbShadowColor)
    ]
)
ctx.restoreGState()

// ─── 6. Front orbit ring (bright arc in front of the orb) ──────────────────
drawOrbit(clippedFrontOnly: true, color: spec.orbitFrontColor, strokeWidth: spec.orbitStroke)

// ─── 7. Sub-agent (amethyst) ───────────────────────────────────────────────
let subCx = orbCx + CGFloat(spec.subOffset.x) * scale
let subCy = orbCy + CGFloat(spec.subOffset.y) * scale
let subR = CGFloat(spec.subDiameter) * scale / 2

// Glow behind it.
radial(
    centre: CGPoint(x: subCx, y: subCy),
    startR: subR * 0.6,
    endR: CGFloat(spec.subGlowRadius) * scale,
    stops: [
        (0.00, spec.subGlow),
        (1.00, NSColor.clear)
    ]
)

// Sphere body.
ctx.saveGState()
let subRect = CGRect(x: subCx - subR, y: subCy - subR, width: subR * 2, height: subR * 2)
ctx.addPath(CGPath(ellipseIn: subRect, transform: nil))
ctx.clip()
let subHighlightCentre = CGPoint(x: subCx - subR * 0.30, y: subCy - subR * 0.40)
radial(
    centre: subHighlightCentre,
    startR: 0,
    endR: subR * 1.3,
    stops: [
        (0.00, spec.subHighlight),
        (0.60, spec.subBody),
        (1.00, spec.subDeep)
    ]
)
ctx.restoreGState()

// ─── 8. Top sheen ──────────────────────────────────────────────────────────
// Very subtle white gradient across the top of the tile, gone by 38% down.
// Fakes a glass-sphere reflection so the icon reads as raised at small sizes.
//
// The context was flipped near the top of the render (translateBy y=size,
// scaleBy y=-1) so we can transcribe design coords with a top-left origin.
// In flipped user space, y=0 is the top edge of the tile and y=size is the
// bottom — so the sheen must run from (0, 0) down to (0, size) to sit
// across the top of the icon, matching what the comment above describes.
let sheenSpace = CGColorSpaceCreateDeviceRGB()
let sheenColors = [
    NSColor.white.withAlphaComponent(spec.sheenAlpha).cgColor,
    NSColor.clear.cgColor
] as CFArray
let sheenLocations: [CGFloat] = [0.0, CGFloat(spec.sheenFalloff)]
if let sheen = CGGradient(colorsSpace: sheenSpace, colors: sheenColors, locations: sheenLocations) {
    ctx.drawLinearGradient(
        sheen,
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: 0, y: size),
        options: [.drawsAfterEndLocation]
    )
}

ctx.restoreGState()

// ─── Export ─────────────────────────────────────────────────────────────────

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

do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try pngData.write(to: outURL)
    print("wrote \(outURL.path)")
} catch {
    fputs("failed to write icon: \(error.localizedDescription)\n", stderr)
    exit(1)
}
