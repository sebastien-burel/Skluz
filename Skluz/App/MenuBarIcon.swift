import AppKit

enum MenuBarIconStatus: Equatable {
    case neutral        // tous arrêtés
    case running        // au moins un running, aucun échec
    case reconnecting   // au moins un en reconnexion, aucun échec
    case failed         // au moins un échec (priorité max)
}

/// Icône menubar « écluse » : glyphe template (asset MenuBarIcon, fond
/// transparent, recoloré par macOS selon le thème) surmonté d'une pastille
/// de couleur signalant l'état agrégé des tunnels (plan §3).
enum MenuBarIcon {
    private static let glyphSize = NSSize(width: 18, height: 18)

    static func image(status: MenuBarIconStatus) -> NSImage {
        let glyph = NSImage(named: "MenuBarIcon") ?? NSImage(
            systemSymbolName: "circle.grid.cross", accessibilityDescription: "Skluz"
        )!
        glyph.size = glyphSize

        guard let color = badgeColor(for: status) else {
            glyph.isTemplate = true        // macOS gère clair/sombre
            return glyph
        }

        let composed = NSImage(size: glyphSize, flipped: false) { rect in
            // Glyphe teinté (labelColor s'adapte raisonnablement à la barre).
            glyph.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            drawBadge(color: color, canvas: rect.size)
            return true
        }
        composed.isTemplate = false
        return composed
    }

    private static func badgeColor(for status: MenuBarIconStatus) -> NSColor? {
        switch status {
        case .neutral:      nil
        case .running:      .systemGreen
        case .reconnecting: .systemOrange
        case .failed:       .systemRed
        }
    }

    private static func drawBadge(color: NSColor, canvas: NSSize) {
        let diameter: CGFloat = canvas.width * 0.42
        let rect = NSRect(
            x: canvas.width - diameter,
            y: 0,
            width: diameter,
            height: diameter
        )
        let halo = NSBezierPath(ovalIn: rect.insetBy(dx: -1, dy: -1))
        NSColor.windowBackgroundColor.setFill()
        halo.fill()

        let dot = NSBezierPath(ovalIn: rect)
        color.setFill()
        dot.fill()
    }
}
