// Génère le jeu AppIcon de Skluz, dans le style des apps Haruni (TyKaoz,
// Dasson) : fond bleu nuit uni, glyphe blanc arrondi, accent turquoise.
//
// Le glyphe est l'écluse : deux portes, la traverse, et l'eau qui passe —
// une vague grise derrière, une vague turquoise devant. Jusqu'à 32 px, un
// dessin simplifié (une seule vague, trait plus épais) reste lisible.
//
// Usage : swift Tools/generate_appicon.swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Couleurs relevées sur les icônes de TyKaoz et Dasson (sRGB).
let navy = NSColor(srgbRed: 0x0D / 255, green: 0x24 / 255, blue: 0x40 / 255, alpha: 1)
let teal = NSColor(srgbRed: 0x2C / 255, green: 0x9F / 255, blue: 0xB3 / 255, alpha: 1)
let mist = NSColor(srgbRed: 0xB7 / 255, green: 0xBE / 255, blue: 0xC6 / 255, alpha: 1)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

struct Glyph {
    /// Size of the glyph relative to the full-size design.
    var scale: CGFloat
    /// Stroke thickness relative to the full-size design.
    var strokeFactor: CGFloat
    /// The grey back wave; dropped at small sizes, where it blurs into the other.
    var hasBackWave: Bool
    /// Heights in unit coordinates, between the gate ends (0.30 and 0.70):
    /// the beam and the waves are spread so that each band stays distinct.
    var beamY: CGFloat = 0.650
    var backWaveY: CGFloat = 0.520
    var frontWaveY: CGFloat = 0.385

    static let full = Glyph(scale: 0.95, strokeFactor: 1.18, hasBackWave: true)
    static let small = Glyph(scale: 0.99, strokeFactor: 1.35, hasBackWave: false, frontWaveY: 0.475)
}

/// One sine period across the lock, in unit coordinates centered on (0.5, 0.5).
func wave(at y: CGFloat, amplitude: CGFloat, from x0: CGFloat, to x1: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 64
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let point = NSPoint(x: x0 + (x1 - x0) * t, y: y + amplitude * sin(t * 2 * .pi))
        i == 0 ? path.move(to: point) : path.line(to: point)
    }
    return path
}

func line(from a: NSPoint, to b: NSPoint) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: a)
    path.line(to: b)
    return path
}

func render(side: Int, glyph: Glyph) -> CGImage {
    let s = CGFloat(side)
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

    // macOS grid: an 824/1024 body with a soft drop shadow below it.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset * 1.12, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = s * 0.018
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    shadow.set()
    navy.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Unit coordinates around (0.5, 0.5), scaled into the body.
    var transform = AffineTransform(translationByX: -0.5, byY: -0.5)
    transform.append(AffineTransform(scale: s * glyph.scale))
    transform.append(AffineTransform(translationByX: s / 2, byY: body.midY))
    func stroke(_ path: NSBezierPath, _ color: NSColor) {
        path.transform(using: transform)
        path.lineWidth = s * 0.072 * glyph.scale * glyph.strokeFactor
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    let left: CGFloat = 0.285, right: CGFloat = 0.715
    // Water behind the gates, so the gates read in front.
    if glyph.hasBackWave {
        stroke(wave(at: glyph.backWaveY, amplitude: 0.022, from: left, to: right), mist)
    }
    stroke(wave(at: glyph.frontWaveY, amplitude: 0.022, from: left, to: right), teal)
    for x: CGFloat in [0.395, 0.605] {
        stroke(line(from: NSPoint(x: x, y: 0.300), to: NSPoint(x: x, y: 0.700)), .white)
    }
    stroke(line(from: NSPoint(x: left, y: glyph.beamY), to: NSPoint(x: right, y: glyph.beamY)), .white)

    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                      UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("écriture impossible : \(path)") }
}

let setDir = "Skluz/Assets.xcassets/AppIcon.appiconset"
let entries: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2),
    (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)
]

var images: [[String: String]] = []
for entry in entries {
    let px = entry.size * entry.scale
    let name = "icon_\(entry.size)x\(entry.size)@\(entry.scale)x.png"
    writePNG(render(side: px, glyph: px <= 32 ? .small : .full), to: "\(setDir)/\(name)")
    images.append([
        "idiom": "mac",
        "scale": "\(entry.scale)x",
        "size": "\(entry.size)x\(entry.size)",
        "filename": name
    ])
}

let contents: [String: Any] = [
    "images": images,
    "info": ["author": "xcode", "version": 1]
]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: "\(setDir)/Contents.json"))
print("AppIcon généré : \(entries.count) images (dessin simplifié jusqu'à 32 px).")
