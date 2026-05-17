// Génère le set AppIcon (palette Haruni) — placeholder perfectible.
// Usage : swift Tools/generate_appicon.swift
import AppKit

let palette = (
    paper: NSColor(srgbRed: 0.980, green: 0.972, blue: 0.965, alpha: 1), // #FAF8F6
    ink:   NSColor(srgbRed: 0.176, green: 0.141, blue: 0.125, alpha: 1), // #2D2420
    terra: NSColor(srgbRed: 0.910, green: 0.365, blue: 0.227, alpha: 1)  // #E85D3A
)

// Master fourni par un designer : Tools/icon-master.png (carré, idéalement
// 1024×1024, forme/ombre déjà incluses). S'il est présent, on se contente
// de le redimensionner ; sinon on dessine le placeholder Core Graphics.
let masterPath = "Tools/icon-master.png"
let master = NSImage(contentsOfFile: masterPath)
if master != nil { print("Master détecté (\(masterPath)) : découpe par redimensionnement.") }

func newRep(_ side: CGFloat) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
}

func drawIcon(side: CGFloat) -> NSBitmapImageRep {
    if let master {
        let rep = newRep(side)
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        ctx?.imageInterpolation = .high
        NSGraphicsContext.current = ctx
        master.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            from: .zero, operation: .copy, fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    return drawPlaceholder(side: side)
}

func drawPlaceholder(side: CGFloat) -> NSBitmapImageRep {
    let rep = newRep(side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    // Squircle macOS : marge ~ 1/16, rayon ~ 0.224.
    let inset = side * 0.0625
    let body = rect.insetBy(dx: inset, dy: inset)
    let radius = body.width * 0.224
    let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    palette.paper.setFill()
    squircle.fill()
    palette.ink.withAlphaComponent(0.12).setStroke()
    squircle.lineWidth = side * 0.006
    squircle.stroke()

    // Écluse : deux portes + passage (terracotta).
    let cx = side / 2, cy = side / 2
    let gateHalf = side * 0.22
    let gateX = side * 0.16
    let lineW = side * 0.052

    palette.ink.setStroke()
    for dx in [-gateX, gateX] {
        let gate = NSBezierPath()
        gate.move(to: NSPoint(x: cx + dx, y: cy - gateHalf))
        gate.line(to: NSPoint(x: cx + dx, y: cy + gateHalf))
        gate.lineWidth = lineW
        gate.lineCapStyle = .round
        gate.stroke()
    }

    let passage = NSBezierPath()
    passage.move(to: NSPoint(x: cx - side * 0.30, y: cy))
    passage.line(to: NSPoint(x: cx + side * 0.30, y: cy))
    passage.lineWidth = lineW * 1.05
    passage.lineCapStyle = .round
    palette.terra.setStroke()
    passage.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
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
    let rep = drawIcon(side: CGFloat(px))
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(setDir)/\(name)"))
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
let json = try! JSONSerialization.data(
    withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]
)
try! json.write(to: URL(fileURLWithPath: "\(setDir)/Contents.json"))
print("AppIcon set généré : \(entries.count) images.")
