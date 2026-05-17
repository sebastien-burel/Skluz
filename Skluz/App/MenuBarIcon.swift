import AppKit

enum MenuBarIconStatus: Equatable {
    case neutral        // tous arrêtés
    case running        // au moins un running, aucun échec
    case reconnecting   // au moins un en reconnexion, aucun échec
    case failed         // au moins un échec (priorité max)
}

/// Icône menubar « écluse » dessinée par Core Graphics (plan §3) :
/// deux portes verticales + le passage horizontal. Un pastille de
/// couleur signale l'état agrégé des tunnels.
enum MenuBarIcon {
    static func image(status: MenuBarIconStatus) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            drawLock()
            if let color = badgeColor(for: status) {
                drawBadge(color: color, canvas: size)
            }
            return true
        }
        // Template (adaptatif clair/sombre) seulement sans pastille colorée.
        image.isTemplate = (status == .neutral)
        return image
    }

    private static func drawLock() {
        let stroke = NSColor.labelColor
        stroke.setStroke()

        // Portes (deux traits verticaux courts).
        for x in [7.5, 14.5] {
            let gate = NSBezierPath()
            gate.move(to: NSPoint(x: x, y: 5))
            gate.line(to: NSPoint(x: x, y: 17))
            gate.lineWidth = 2.2
            gate.lineCapStyle = .round
            gate.stroke()
        }

        // Passage (trait horizontal qui traverse au centre).
        let passage = NSBezierPath()
        passage.move(to: NSPoint(x: 3.5, y: 11))
        passage.line(to: NSPoint(x: 18.5, y: 11))
        passage.lineWidth = 2.2
        passage.lineCapStyle = .round
        passage.stroke()
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
        let diameter: CGFloat = 8
        let rect = NSRect(
            x: canvas.width - diameter - 1,
            y: 0.5,
            width: diameter,
            height: diameter
        )
        // Liseré pour détacher la pastille du glyphe.
        let halo = NSBezierPath(ovalIn: rect.insetBy(dx: -1.2, dy: -1.2))
        NSColor.windowBackgroundColor.setFill()
        halo.fill()

        let dot = NSBezierPath(ovalIn: rect)
        color.setFill()
        dot.fill()
    }
}
