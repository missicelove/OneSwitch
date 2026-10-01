import AppKit
import CoreText

/// Renders status segments into a menu-bar image with a width that depends only on the metric and
/// style (never on the current values), so the menu bar does not jitter.
public enum StatusRenderer {
    public enum Tint: Equatable {
        /// Monochrome template image — the system tints it for light / dark menu bars.
        case template
        /// Explicit colours (used when a value is in the warning range).
        case colored(dark: Bool)
    }

    public struct TextRun: Equatable {
        public enum Role: Equatable { case caption, value, prefix }
        public var text: String
        public var font: NSFont
        /// Left edge of the allotted box and the baseline.
        public var origin: CGPoint
        public var boxWidth: CGFloat
        public var alignment: NSTextAlignment
        public var role: Role
        public var level: AlertLevel
    }

    public struct IconRun: Equatable {
        public var symbol: String
        public var rect: CGRect
    }

    public struct SparkRun: Equatable {
        public var rect: CGRect
        public var primary: [Double]
        public var secondary: [Double]?
    }

    public struct Layout: Equatable {
        public var size: CGSize
        public var texts: [TextRun] = []
        public var icons: [IconRun] = []
        public var sparks: [SparkRun] = []
    }

    // Fonts: values use monospaced digits (9–10 pt) so the digits never shift.
    public static let captionFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
    public static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    public static let lineFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    static let segmentGap: CGFloat = 7
    static let padding: CGFloat = 1
    static let iconBox: CGFloat = 14
    static let iconGap: CGFloat = 2
    static let prefixGap: CGFloat = 1.5
    static let sparkGap: CGFloat = 3
    static let sparkWidth = CGFloat(StatusContent.sparkSamples) + 2
    static let captionGap: CGFloat = 3
    static let lineGap: CGFloat = 3.2

    // MARK: Public API

    public static func image(for segments: [StatusSegment], style: DisplayStyle, height: CGFloat, tint: Tint) -> NSImage {
        let layout = self.layout(segments, style: style, height: height)
        let image = NSImage(size: layout.size, flipped: false) { _ in
            draw(layout, tint: tint)
            return true
        }
        image.isTemplate = (tint == .template)
        image.accessibilityDescription = segments.map(\.accessibilityText).joined(separator: "，")
        return image
    }

    /// Typographic width of `text` in `font` (with font fallback, as drawn).
    public static func width(_ text: String, font: NSFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, font: font), nil, nil, nil))
    }

    public static func layout(_ segments: [StatusSegment], style: DisplayStyle, height: CGFloat) -> Layout {
        var layout = Layout(size: CGSize(width: 0, height: height))
        var x = padding
        for (i, segment) in segments.enumerated() {
            if i > 0 { x += segmentGap }
            x = place(segment, style: style, x: x, height: height, into: &layout)
        }
        layout.size.width = ceil(max(1, x + padding))
        return layout
    }

    // MARK: Layout

    private static func place(_ segment: StatusSegment, style: DisplayStyle, x startX: CGFloat,
                              height: CGFloat, into layout: inout Layout) -> CGFloat {
        var x = startX
        switch style {
        case .text:
            break
        case .iconValue:
            let y = ((height - iconBox) / 2).rounded()
            layout.icons.append(IconRun(symbol: segment.metric.symbolName, rect: CGRect(x: x, y: y, width: iconBox, height: iconBox)))
            x += iconBox + iconGap
        case .sparkline:
            let inset: CGFloat = 3
            layout.sparks.append(SparkRun(rect: CGRect(x: x, y: inset, width: sparkWidth, height: height - 2 * inset),
                                          primary: segment.spark, secondary: segment.spark2))
            x += sparkWidth + sparkGap
        }

        switch segment.body {
        case let .captioned(caption, value, templates):
            let valueWidth = ceil(maxWidth(templates + [value], font: valueFont))
            if style == .iconValue {
                // The icon replaces the caption: one centred value line.
                let baseline = snap((height - valueFont.capHeight) / 2)
                layout.texts.append(TextRun(text: value, font: valueFont, origin: CGPoint(x: x, y: baseline),
                                            boxWidth: valueWidth, alignment: .right, role: .value, level: segment.level))
                return x + valueWidth
            }
            let captionWidth = width(caption, font: captionFont)
            let w = ceil(max(captionWidth, valueWidth))
            let total = captionFont.capHeight + captionGap + valueFont.capHeight
            let bottom = snap((height - total) / 2)
            let top = snap(bottom + valueFont.capHeight + captionGap)
            layout.texts.append(TextRun(text: caption, font: captionFont, origin: CGPoint(x: x, y: top),
                                        boxWidth: w, alignment: .center, role: .caption, level: .normal))
            layout.texts.append(TextRun(text: value, font: valueFont, origin: CGPoint(x: x, y: bottom),
                                        boxWidth: w, alignment: .center, role: .value, level: segment.level))
            return x + w

        case let .stacked(topLine, bottomLine):
            let prefixWidth = ceil(maxWidth([topLine.prefix, bottomLine.prefix], font: lineFont))
            let valueWidth = ceil(maxWidth(topLine.templates + bottomLine.templates + [topLine.value, bottomLine.value], font: lineFont))
            let total = lineFont.capHeight * 2 + lineGap
            let bottom = snap((height - total) / 2)
            let top = snap(bottom + lineFont.capHeight + lineGap)
            for (line, baseline) in [(topLine, top), (bottomLine, bottom)] {
                layout.texts.append(TextRun(text: line.prefix, font: lineFont, origin: CGPoint(x: x, y: baseline),
                                            boxWidth: prefixWidth, alignment: .left, role: .prefix, level: .normal))
                layout.texts.append(TextRun(text: line.value, font: lineFont,
                                            origin: CGPoint(x: x + prefixWidth + prefixGap, y: baseline),
                                            boxWidth: valueWidth, alignment: .right, role: .value, level: segment.level))
            }
            return x + prefixWidth + prefixGap + valueWidth
        }
    }

    /// Width of the widest string. Values are included defensively: a value can only widen the column
    /// if it is wider than every template, which the formatters prevent (verified by the checks).
    private static func maxWidth(_ strings: [String], font: NSFont) -> CGFloat {
        strings.map { width($0, font: font) }.max() ?? 0
    }

    private static func snap(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }

    // MARK: Drawing

    private static func line(_ text: String, font: NSFont) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    static func color(for level: AlertLevel, base: NSColor) -> NSColor {
        switch level {
        case .normal: return base
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    private static func draw(_ layout: Layout, tint: Tint) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let base: NSColor
        let colored: Bool
        switch tint {
        case .template:
            base = .black
            colored = false
        case .colored(let dark):
            base = dark ? .white : NSColor(white: 0, alpha: 0.85)
            colored = true
        }

        for spark in layout.sparks { drawSpark(spark, color: base) }

        for icon in layout.icons {
            guard let symbol = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) else { continue }
            let s = symbol.size
            let scale = min(icon.rect.width / max(1, s.width), icon.rect.height / max(1, s.height), 1)
            let size = CGSize(width: s.width * scale, height: s.height * scale)
            let rect = CGRect(x: icon.rect.midX - size.width / 2, y: icon.rect.midY - size.height / 2,
                              width: size.width, height: size.height)
            if colored {
                tinted(symbol, color: base).draw(in: rect)
            } else {
                symbol.draw(in: rect)
            }
        }

        for run in layout.texts {
            let line = self.line(run.text, font: run.font)
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            var x = run.origin.x
            switch run.alignment {
            case .center: x += (run.boxWidth - w) / 2
            case .right: x += run.boxWidth - w
            default: break
            }
            let c = colored ? color(for: run.level, base: base) : base
            ctx.saveGState()
            ctx.setFillColor(c.cgColor)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: x, y: run.origin.y)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    private static func drawSpark(_ run: SparkRun, color: NSColor) {
        let frame = NSBezierPath(roundedRect: run.rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 2, yRadius: 2)
        frame.lineWidth = 0.5
        color.withAlphaComponent(0.4).setStroke()
        frame.stroke()

        let inner = run.rect.insetBy(dx: 1, dy: 1)
        func path(_ values: [Double]) -> [CGPoint] {
            Sparkline.points(normalized: values, capacity: StatusContent.sparkSamples,
                             width: Double(inner.width), height: Double(inner.height))
                .map { CGPoint(x: inner.minX + $0.x, y: inner.minY + $0.y) }
        }
        let primary = path(run.primary)
        if primary.count >= 2 {
            let area = NSBezierPath()
            area.move(to: CGPoint(x: primary[0].x, y: inner.minY))
            primary.forEach { area.line(to: $0) }
            area.line(to: CGPoint(x: primary[primary.count - 1].x, y: inner.minY))
            area.close()
            color.withAlphaComponent(0.45).setFill()
            area.fill()
            let stroke = NSBezierPath()
            stroke.move(to: primary[0])
            primary.dropFirst().forEach { stroke.line(to: $0) }
            stroke.lineWidth = 1
            color.setStroke()
            stroke.stroke()
        }
        if let secondary = run.secondary {
            let pts = path(secondary)
            if pts.count >= 2 {
                let stroke = NSBezierPath()
                stroke.move(to: pts[0])
                pts.dropFirst().forEach { stroke.line(to: $0) }
                stroke.lineWidth = 0.8
                stroke.setLineDash([1.5, 1], count: 2, phase: 0)
                color.withAlphaComponent(0.9).setStroke()
                stroke.stroke()
            }
        }
    }

    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
