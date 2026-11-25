import AppKit

/// Draws the menu bar readout as one template image so macOS tints it for any wallpaper.
@MainActor
enum MenuBarRenderer {
    static let height: CGFloat = 22

    /// Hours since local midnight, counting the current one.
    static var hoursToday: Int {
        Calendar.current.component(.hour, from: Date()) + 1
    }

    @MainActor private enum Segment {
        case text(String)
        case stacked(String, String)
        case sparkline([Float])
        case icon(NSImage)
        case blank(CGFloat)

        var width: CGFloat {
            switch self {
            case .text(let s): return ceil(NSAttributedString(string: s, attributes: MenuBarRenderer.textAttributes).size().width)
            case .stacked(let a, let b):
                let wa = NSAttributedString(string: a, attributes: MenuBarRenderer.smallAttributes).size().width
                let wb = NSAttributedString(string: b, attributes: MenuBarRenderer.smallAttributes).size().width
                return ceil(max(wa, wb))
            case .sparkline: return 34
            case .icon(let image): return image.size.width
            case .blank(let width): return width
            }
        }
    }

    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.black,
    ]

    private static let smallAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
        .foregroundColor: NSColor.black,
    ]

    /// Where the logo goes: drawn in, left as a gap for a colored one laid on top, or left out.
    enum LogoMode { case inline, space, none }

    static func image(store: TelemetryStore, settings: Settings, leadingInset: CGFloat, logo logoMode: LogoMode = .inline) -> NSImage {
        var segments: [Segment] = []
        let state = store.state

        switch logoMode {
        case .inline: segments.append(.icon(logo(online: state.isUp)))
        case .space: segments.append(.blank(logo(online: state.isUp).size.width))
        case .none: break
        }

        // When something's wrong, say what. A dish that's down has no numbers worth showing.
        switch state {
        case .online: break
        // A dish colored by status already says it's degraded; the tooltip and popover say why.
        case .degraded(let why): if !settings.showStatusDot { segments.append(.text(why)) }
        case .offline(let why): segments.append(.text(why))
        case .unreachable: segments.append(.text("No dish"))
        }

        if let dish = store.dish, store.dishError == nil, state.isUp {
            for item in settings.menuBarItems {
                switch item {
                case .latency:
                    segments.append(.text(state.isUp ? Fmt.ms(dish.latencyMs) : Fmt.missing))
                case .data:
                    let today = store.totals(Self.hoursToday)
                    segments.append(.text(Fmt.data(today.down + today.up)))
                case .throughput:
                    segments.append(.stacked(
                        "↑ " + Fmt.rate(dish.upBps, bytes: settings.useBytes),
                        "↓ " + Fmt.rate(dish.downBps, bytes: settings.useBytes)
                    ))
                case .power:
                    segments.append(.text(Fmt.watts(store.powerW)))
                case .obstruction:
                    segments.append(.text(Fmt.percent(dish.obstruction.fraction)))
                case .events:
                    let count = store.outages(since: 3600).count
                    segments.append(.text("\(count) " + (count == 1 ? "outage" : "outages")))
                case .sparkline:
                    segments.append(.sparkline(store.window(90).map { $0.drop >= 1 ? 0 : $0.latency }))
                }
            }
        }

        let gap: CGFloat = 6
        let width = leadingInset + segments.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, segments.count - 1))
        let size = NSSize(width: ceil(width), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            var x = leadingInset
            for segment in segments {
                switch segment {
                case .icon(let symbol):
                    let rect = NSRect(x: x, y: (height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
                    symbol.draw(in: rect)
                case .text(let s):
                    let str = NSAttributedString(string: s, attributes: textAttributes)
                    str.draw(at: NSPoint(x: x, y: (height - str.size().height) / 2))
                case .stacked(let top, let bottom):
                    let w = segment.width
                    let a = NSAttributedString(string: top, attributes: smallAttributes)
                    let b = NSAttributedString(string: bottom, attributes: smallAttributes)
                    a.draw(at: NSPoint(x: x + w - a.size().width, y: height / 2 - 0.5))
                    b.draw(at: NSPoint(x: x + w - b.size().width, y: height / 2 - b.size().height + 0.5))
                case .sparkline(let values):
                    drawSparkline(values, in: NSRect(x: x, y: 5, width: segment.width, height: height - 10))
                case .blank: break
                }
                x += segment.width + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The app icon's dish and satellite, without its tile. Offline, the signal arcs go and the satellite fades.
    /// With a color it's drawn in that color instead of as a template, so it can show the link state.
    static func logo(online: Bool, height: CGFloat = 17, color: NSColor? = nil) -> NSImage {
        let ink = color ?? .black
        // The icon's artwork spans about x 19...92, y 15...88 of its 100-unit square.
        let box = NSRect(x: 19, y: 15, width: 73, height: 73)
        let scale = height / box.height
        let image = NSImage(size: NSSize(width: ceil(box.width * scale), height: height), flipped: true) { _ in
            let t = NSAffineTransform()
            t.scale(by: scale)
            t.translateX(by: -box.minX, yBy: -box.minY)
            t.concat()
            ink.set()
            func line(_ a: NSPoint, _ b: NSPoint, width: CGFloat = 4) {
                let p = NSBezierPath(); p.move(to: a); p.line(to: b)
                p.lineWidth = width; p.lineCapStyle = .round; p.stroke()
            }
            line(NSPoint(x: 49, y: 71), NSPoint(x: 49, y: 85))
            line(NSPoint(x: 39, y: 85), NSPoint(x: 59, y: 85))
            let dish = NSBezierPath()
            dish.move(to: NSPoint(x: 76, y: 62)); dish.line(to: NSPoint(x: 43, y: 40))
            dish.line(to: NSPoint(x: 22, y: 54)); dish.line(to: NSPoint(x: 55, y: 76)); dish.close()
            dish.lineWidth = 4; dish.lineJoinStyle = .round
            dish.fill(); dish.stroke()
            if online {
                // Arcs centred on (72, 28), the satellite, from the SVG's arc endpoints.
                for (radius, alpha) in [(10.0, 1.0), (17.0, 0.55)] as [(CGFloat, CGFloat)] {
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: NSPoint(x: 72, y: 28), radius: radius, startAngle: 153, endAngle: 103, clockwise: true)
                    arc.lineWidth = 4; arc.lineCapStyle = .round
                    ink.withAlphaComponent(alpha).setStroke(); arc.stroke()
                }
            }
            ink.withAlphaComponent(online ? 1 : 0.35).set()
            let sat = NSAffineTransform()
            sat.translateX(by: 72, yBy: 28); sat.rotate(byDegrees: 35); sat.translateX(by: -72, yBy: -28)
            sat.concat()
            NSBezierPath(roundedRect: NSRect(x: 56, y: 25.5, width: 10.5, height: 5), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: NSRect(x: 77.5, y: 25.5, width: 10.5, height: 5), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: NSRect(x: 68.5, y: 24.5, width: 7, height: 7), xRadius: 1.5, yRadius: 1.5).fill()
            line(NSPoint(x: 66.5, y: 28), NSPoint(x: 77.5, y: 28), width: 1.8)
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = "StarDash"
        return image
    }

    private static func drawSparkline(_ values: [Float], in rect: NSRect) {
        guard values.count > 1 else { return }
        let top = max(values.max() ?? 1, 60)
        let path = NSBezierPath()
        for (i, v) in values.enumerated() {
            let px = rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1)
            let py = rect.minY + rect.height * CGFloat(min(v, top) / top)
            if i == 0 { path.move(to: NSPoint(x: px, y: py)) } else { path.line(to: NSPoint(x: px, y: py)) }
        }
        path.lineWidth = 1.2
        path.lineJoinStyle = .round
        NSColor.black.setStroke()
        path.stroke()
    }
}
