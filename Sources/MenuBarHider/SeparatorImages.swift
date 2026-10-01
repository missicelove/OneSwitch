import AppKit

/// Template images for the toggle and separators (drawn in code so they stay crisp at any scale and
/// follow the menu bar's light / dark appearance).
enum HiderImages {
    static let barIconHeight: CGFloat = 16

    /// Thin vertical line.
    static func line(dashed: Bool = false) -> NSImage {
        let size = NSSize(width: 4, height: barIconHeight)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            let lineRect = NSRect(x: (rect.width - 1.5) / 2, y: 1, width: 1.5, height: rect.height - 2)
            if dashed {
                let dash: CGFloat = 3, gap: CGFloat = 2
                var y = lineRect.minY
                while y < lineRect.maxY {
                    NSBezierPath(roundedRect: NSRect(x: lineRect.minX, y: y, width: lineRect.width,
                                                     height: min(dash, lineRect.maxY - y)),
                                 xRadius: 0.75, yRadius: 0.75).fill()
                    y += dash + gap
                }
            } else {
                NSBezierPath(roundedRect: lineRect, xRadius: 0.75, yRadius: 0.75).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Small filled (or hollow) dot.
    static func dot(diameter: CGFloat = 5, hollow: Bool = false) -> NSImage {
        let size = NSSize(width: diameter + 2, height: barIconHeight)
        let image = NSImage(size: size, flipped: false) { rect in
            let circle = NSRect(x: (rect.width - diameter) / 2, y: (rect.height - diameter) / 2,
                                width: diameter, height: diameter)
            if hollow {
                NSColor.black.setStroke()
                let path = NSBezierPath(ovalIn: circle.insetBy(dx: 0.6, dy: 0.6))
                path.lineWidth = 1.2
                path.stroke()
            } else {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: circle).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func separator(style: SeparatorStyle, alwaysHidden: Bool) -> NSImage {
        switch style {
        case .line: return line(dashed: alwaysHidden)
        case .dot: return dot(diameter: alwaysHidden ? 4 : 5, hollow: alwaysHidden)
        }
    }

    /// The toggle icon drawn at the right edge of a `width`-wide image (widened collapsed toggle).
    static func wideToggle(style: ToggleIconStyle, warning: Bool, width: CGFloat) -> NSImage? {
        guard let icon = toggle(style: style, expanded: false, warning: warning) else { return nil }
        let size = NSSize(width: max(width, icon.size.width), height: max(barIconHeight, icon.size.height))
        let image = NSImage(size: size, flipped: false) { rect in
            let s = icon.size
            icon.draw(in: NSRect(x: rect.maxX - s.width, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    static func toggle(style: ToggleIconStyle, expanded: Bool, warning: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        if warning {
            let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "分隔线位置不正确")?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            return image
        }
        switch style {
        case .chevron:
            let name = expanded ? "chevron.right" : "chevron.left"
            let image = NSImage(systemSymbolName: name, accessibilityDescription: expanded ? "隐藏菜单栏图标" : "显示隐藏的菜单栏图标")?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            return image
        case .dot:
            return dot(diameter: 7, hollow: expanded)
        }
    }
}
