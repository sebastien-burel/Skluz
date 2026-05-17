// Recadre le viewBox du SVG menubar sur la bounding box réelle du glyphe
// (supprime la marge transparente) pour qu'il remplisse l'icône.
// Usage : swift Tools/fit_menubar_svg.swift
import AppKit

let svgPath = "Skluz/Assets.xcassets/MenuBarIcon.imageset/menubar-glyph.svg"
var svg = try String(contentsOfFile: svgPath, encoding: .utf8)

// viewBox actuel : "minX minY W H"
guard let vbRange = svg.range(of: #"viewBox="[^"]*""#, options: .regularExpression) else {
    FileHandle.standardError.write(Data("viewBox introuvable\n".utf8)); exit(1)
}
let vbValues = svg[vbRange]
    .replacingOccurrences(of: "viewBox=\"", with: "")
    .replacingOccurrences(of: "\"", with: "")
    .split(separator: " ").compactMap { Double($0) }
guard vbValues.count == 4 else {
    FileHandle.standardError.write(Data("viewBox malformé\n".utf8)); exit(1)
}
let (vbX, vbY, vbW, vbH) = (vbValues[0], vbValues[1], vbValues[2], vbValues[3])

// Rendu du SVG dans un buffer RGBA connu.
guard let img = NSImage(contentsOfFile: svgPath) else {
    FileHandle.standardError.write(Data("NSImage ne lit pas le SVG\n".utf8)); exit(1)
}
let S = 1024
img.size = NSSize(width: S, height: S)
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8,
                          bytesPerRow: S * 4, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ns
img.draw(in: NSRect(x: 0, y: 0, width: S, height: S))
NSGraphicsContext.restoreGraphicsState()

guard let raw = ctx.data else { exit(1) }
let px = raw.bindMemory(to: UInt8.self, capacity: S * S * 4)
var minX = S, minY = S, maxX = -1, maxY = -1
for y in 0..<S {
    for x in 0..<S where px[(y * S + x) * 4 + 3] > 12 {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}
guard maxX >= 0 else {
    FileHandle.standardError.write(Data("Glyphe vide au rendu\n".utf8)); exit(1)
}

// Pixels → unités viewBox. CGContext : origine en bas-gauche ; SVG : en haut-gauche.
let sx = vbW / Double(S), sy = vbH / Double(S)
let gx = vbX + Double(minX) * sx
let gw = Double(maxX - minX + 1) * sx
let gh = Double(maxY - minY + 1) * sy
let gy = vbY + Double(S - 1 - maxY) * sy

// Marge légère + carré (même côté X/Y pour ne pas déformer).
let side = max(gw, gh)
let margin = side * 0.08
let box = side + 2 * margin
let newX = gx - (box - gw) / 2
let newY = gy - (box - gh) / 2

let newVB = String(format: "viewBox=\"%.1f %.1f %.1f %.1f\"", newX, newY, box, box)
svg.replaceSubrange(vbRange, with: newVB)
try svg.write(toFile: svgPath, atomically: true, encoding: .utf8)
print("viewBox recadré : \(newVB)")
