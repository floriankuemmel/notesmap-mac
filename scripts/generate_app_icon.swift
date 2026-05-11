#!/usr/bin/env swift
// generate_app_icon.swift — einmaliger Generator für das AppIcon.appiconset.
//
// Rendert per CoreGraphics 10 PNGs (Größen 16/32/64/128/256/512/1024)
// direkt in das übergebene Verzeichnis. Keine externen Dependencies.
//
// Ausführen:
//   swift scripts/generate_app_icon.swift \
//     NotesMap/Resources/Assets.xcassets/AppIcon.appiconset
//
// Design: Graph-Motiv auf tief-blauem Gradient — passt zur App-UI und
// kommuniziert visuell "Verknüpfungs-Map". Zentraler orange Knoten,
// 6 farbige innere Satelliten, 3 äußere — plus Kanten und Stern-Dust.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// --- deterministisches Pseudo-Random für den Sternenstaub ---
// xorshift64*, Seed fest → identisches Sternen-Muster in allen Größen.
var rngState: UInt64 = 0xDEADBEEFCAFEBABE
func rnd() -> Double {
    rngState ^= rngState &>> 12
    rngState ^= rngState &<< 25
    rngState ^= rngState &>> 27
    let out = rngState &* 0x2545F4914F6CDD1D
    return Double(out >> 11) / Double(UInt64.max >> 11)
}

// --- Palette (aus LinkMapHTMLBuilder's folderPalette, leicht angepasst) ---
typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)
let centralColor: RGB = (0.90, 0.49, 0.13)          // #E67E22 Orange
let innerPalette: [RGB] = [
    (0.29, 0.56, 0.85),   // #4A90D9
    (0.15, 0.68, 0.38),   // #27AE60
    (0.61, 0.35, 0.71),   // #9B59B6
    (0.91, 0.30, 0.24),   // #E74C3C
    (0.95, 0.77, 0.06),   // #F1C40F
    (0.10, 0.74, 0.61)    // #1ABC9C
]
let outerPalette: [RGB] = [
    (0.46, 0.27, 0.68),   // gedämpftes Lila
    (0.19, 0.49, 0.73),   // #2980B9 blau
    (0.83, 0.33, 0.13)    // #D35400 orange-dunkel
]

// --- Haupt-Renderer ---
struct IconNode { let pos: CGPoint; let r: CGFloat; let color: RGB; let glow: Bool }

func drawIcon(size: Int) -> CGImage? {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Rounded-Rect-Clip. macOS-App-Icon-Radius ≈ 22.37% der Kantenlänge.
    let radius = s * 0.2237
    let path = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
        cornerWidth: radius, cornerHeight: radius, transform: nil
    )
    ctx.addPath(path)
    ctx.clip()

    // Hintergrund-Gradient (tiefes Space-Blau, wie die App-UI)
    let bg0 = CGColor(red: 0.14, green: 0.17, blue: 0.34, alpha: 1.0)   // oben-links
    let bg1 = CGColor(red: 0.03, green: 0.03, blue: 0.10, alpha: 1.0)   // unten-rechts
    let grad = CGGradient(
        colorsSpace: colorSpace,
        colors: [bg0, bg1] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: s, y: 0),
        options: []
    )

    // Sternenstaub (bei sehr kleinen Icons weggelassen, sonst Pixelrauschen)
    if size >= 64 {
        rngState = 0xDEADBEEFCAFEBABE
        let dustCount = size / 10
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.10)
        for _ in 0..<dustCount {
            let x = CGFloat(rnd()) * s
            let y = CGFloat(rnd()) * s
            let r = CGFloat(rnd()) * (s / 400) + (s / 800)
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
    }

    // --- Knoten berechnen ---
    let center = CGPoint(x: s / 2, y: s / 2)
    let innerR = s * 0.28
    let outerR = s * 0.40

    var innerNodes: [IconNode] = []
    for i in 0..<6 {
        let angle = (Double(i) * 60.0 - 30.0) * .pi / 180
        let p = CGPoint(
            x: center.x + innerR * CGFloat(cos(angle)),
            y: center.y + innerR * CGFloat(sin(angle))
        )
        innerNodes.append(IconNode(pos: p, r: s * 0.058, color: innerPalette[i], glow: true))
    }

    var outerNodes: [IconNode] = []
    for i in 0..<3 {
        let angle = (Double(i) * 120.0 + 30.0) * .pi / 180
        let p = CGPoint(
            x: center.x + outerR * CGFloat(cos(angle)),
            y: center.y + outerR * CGFloat(sin(angle))
        )
        outerNodes.append(IconNode(pos: p, r: s * 0.038, color: outerPalette[i], glow: false))
    }

    let central = IconNode(pos: center, r: s * 0.115, color: centralColor, glow: true)

    // --- Kanten (unter den Knoten) ---
    ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.38)
    ctx.setLineWidth(max(1.0, s * 0.006))
    ctx.setLineCap(.round)

    // Zentrum → inner
    for n in innerNodes {
        ctx.move(to: central.pos); ctx.addLine(to: n.pos); ctx.strokePath()
    }
    // Inner ↔ inner (übernächster Nachbar — Sternenbild)
    for i in 0..<innerNodes.count {
        let j = (i + 2) % innerNodes.count
        ctx.move(to: innerNodes[i].pos); ctx.addLine(to: innerNodes[j].pos); ctx.strokePath()
    }
    // Outer → 2 nächstgelegene inner
    for (idx, o) in outerNodes.enumerated() {
        let a = (idx * 2) % innerNodes.count
        let b = (idx * 2 + 1) % innerNodes.count
        ctx.move(to: o.pos); ctx.addLine(to: innerNodes[a].pos); ctx.strokePath()
        ctx.move(to: o.pos); ctx.addLine(to: innerNodes[b].pos); ctx.strokePath()
    }

    // --- Knoten zeichnen (dunkel nach hell: outer → inner → zentral) ---
    func fillNode(_ n: IconNode) {
        let rect = CGRect(x: n.pos.x - n.r, y: n.pos.y - n.r, width: n.r * 2, height: n.r * 2)
        if n.glow {
            ctx.saveGState()
            let shadowColor = CGColor(red: n.color.r, green: n.color.g, blue: n.color.b, alpha: 0.70)
            ctx.setShadow(offset: .zero, blur: n.r * 1.3, color: shadowColor)
            ctx.setFillColor(red: n.color.r, green: n.color.g, blue: n.color.b, alpha: 1.0)
            ctx.fillEllipse(in: rect)
            ctx.restoreGState()
        } else {
            ctx.setFillColor(red: n.color.r, green: n.color.g, blue: n.color.b, alpha: 1.0)
            ctx.fillEllipse(in: rect)
        }
        // Speculum-Highlight oben-links
        let hlR = n.r * 0.45
        let hlRect = CGRect(
            x: n.pos.x - hlR - n.r * 0.22,
            y: n.pos.y + n.r * 0.22 - hlR,
            width: hlR * 2, height: hlR * 2
        )
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.30)
        ctx.fillEllipse(in: hlRect)
    }
    for n in outerNodes { fillNode(n) }
    for n in innerNodes { fillNode(n) }
    fillNode(central)

    return ctx.makeImage()
}

// --- Output-Loop ---
let outputs: [(name: String, size: Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024)
]

guard CommandLine.arguments.count >= 2 else {
    print("Usage: swift generate_app_icon.swift <AppIcon.appiconset-dir>")
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for item in outputs {
    guard let img = drawIcon(size: item.size) else {
        print("ERROR: Rendering fehlgeschlagen für \(item.size)px"); exit(1)
    }
    let url = outDir.appendingPathComponent(item.name)
    guard let dst = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        print("ERROR: Destination-URL ungültig: \(url.path)"); exit(1)
    }
    CGImageDestinationAddImage(dst, img, nil)
    if !CGImageDestinationFinalize(dst) {
        print("ERROR: Finalize fehlgeschlagen für \(item.name)"); exit(1)
    }
    print("wrote \(item.name) (\(item.size)×\(item.size))")
}

print("Done. 10 PNGs → \(outDir.path)")
