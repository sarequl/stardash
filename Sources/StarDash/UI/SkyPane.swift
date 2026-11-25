import SwiftUI

enum SkyStyle: String, CaseIterable {
    case dome, radar, horizon

    var label: String {
        switch self {
        case .dome: return "3D dome"
        case .radar: return "Radar"
        case .horizon: return "Horizon"
        }
    }

    var hint: String {
        switch self {
        case .dome: return "Drag to turn · scroll to zoom · double-click to reset"
        case .radar: return "Looking straight up · point at any spot to read it"
        case .horizon: return "The sky unrolled · point at any spot to read it"
        }
    }
}

extension ObstructionMap {
    /// The map is a top-down polar picture: centre is straight up, north is the top edge,
    /// and the rim is `maxTheta` degrees away from straight up.
    /// Returns nil outside the map, a negative value where the dish hasn't looked, 0 blocked, 1 clear.
    func sample(azimuth: Double, elevation: Double) -> Float? {
        let r = (90 - elevation) / maxTheta
        guard r >= 0, r <= 1 else { return nil }
        let a = azimuth * .pi / 180
        let col = Int((Double(cols) / 2 + sin(a) * r * Double(cols) / 2).rounded(.down))
        let row = Int((Double(rows) / 2 - cos(a) * r * Double(rows) / 2).rounded(.down))
        guard row >= 0, row < rows, col >= 0, col < cols else { return nil }
        return snr[row * cols + col]
    }

    static func describe(_ value: Float?) -> (text: String, color: Color) {
        guard let value else { return ("Outside what the dish can see", .white.opacity(0.5)) }
        if value < 0 { return ("Not sampled yet", .white.opacity(0.6)) }
        return value < 0.5 ? ("Obstructed", Palette.bad) : ("Clear", Palette.good)
    }
}

struct SkyPane: View {
    @Environment(TelemetryStore.self) private var store
    @AppStorage("skyStyle") private var styleName = SkyStyle.dome.rawValue

    private var style: SkyStyle { SkyStyle(rawValue: styleName) ?? .dome }

    @AppStorage("skySatellites") private var showSatellites = true
    @AppStorage("skyDomeMap") private var showDomeMap = true
    /// Which recorded frame of the map is on screen. Nil means the live map.
    @State private var frame: Int?
    @State private var playing = false
    @State private var locationNote: String?
    @State private var locating = false
    static var stagedFrame: Int?

    var body: some View {
        let frames = store.mapFrames
        let watch = SkyWatch.shared
        let past = (frame ?? Self.stagedFrame).flatMap { $0 < frames.count ? frames[$0] : nil }
        let map = past?.map ?? store.map
        let alignment = store.dish?.alignment
        let site = store.site
        // Satellites are live, so they're hidden while looking at an older map.
        let live = showSatellites && past == nil && site != nil
        let best = live ? watch.bestPlaced(alignment: alignment, map: store.map) : nil
        let sky = SkyOverlay(satellites: live ? watch.satellites : [], ahead: live ? watch.ahead : [:], best: best?.id)
        let lapse = frames.count >= 2

        return HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Group {
                    switch style {
                    case .dome:
                        DomeView(map: map, alignment: alignment, sky: sky, showMap: showDomeMap,
                                 down: store.state.isUp ? store.dish?.downBps : nil,
                                 up: store.state.isUp ? store.dish?.upBps : nil)
                    case .radar:
                        RadarSky(map: map, alignment: alignment, sky: sky)
                            .padding(.top, 120).padding(.bottom, lapse ? 96 : 56).padding(.horizontal, 28)
                    case .horizon:
                        HorizonSky(map: map, alignment: alignment, sky: sky)
                            .padding(.top, 130).padding(.bottom, lapse ? 100 : 60).padding(.horizontal, 28)
                    }
                }
                .transition(.opacity)

                VStack(alignment: .leading, spacing: 6) {
                    PaneTitle("Sky")
                    Text(past.map { "The map as it was \(Fmt.dayClock.string(from: $0.date))" }
                         ?? store.map.map { "\(Fmt.percent($0.coverage, digits: 0)) of the sky mapped so far" } ?? "Waiting for the dish's sky map")
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55))
                        .allowsHitTesting(false)
                    satelliteLine(watch: watch, best: best, hasSite: site != nil)
                }
                .padding(.leading, 28).padding(.top, Theme.paneTop)

                VStack(alignment: .trailing, spacing: 8) {
                    ChipPicker(options: SkyStyle.allCases.map { ($0, $0.label) },
                               selection: Binding(get: { style }, set: { styleName = $0.rawValue }))
                    Toggle("Satellites", isOn: $showSatellites)
                        .toggleStyle(ThemedSwitch())
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.7))
                    if style == .dome {
                        Toggle("Sky map", isOn: $showDomeMap)
                            .toggleStyle(ThemedSwitch())
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 24).padding(.top, 44)

                VStack(spacing: 12) {
                    Spacer().allowsHitTesting(false)
                    if lapse {
                        TimeLapseBar(frames: frames, frame: $frame, playing: $playing)
                            .padding(.horizontal, 28)
                    }
                    HStack(spacing: 16) {
                        if style != .dome || showDomeMap {
                            legend(Palette.accent, "Clear")
                            legend(Palette.bad, "Obstructed")
                        }
                        if live {
                            legend(Palette.link, "Likely connected")
                            legend(.white, "Satellite · hover for its name")
                        }
                        Spacer()
                        Text(style.hint).lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 28).padding(.bottom, 20)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: styleName)
            .onAppear { watch.start(site: { store.site }, floor: { 90 - (store.map?.maxTheta ?? 80) }) }
            .onDisappear { watch.stop() }

            ScrollView {
                SkyTab(showMap: false).padding(.top, Theme.paneTop).padding(.trailing, 24).padding(.bottom, 24)
            }
            .scrollIndicators(.automatic)
            .frame(width: 330)
        }
    }

    /// One line under the title: what's overhead, or how to switch satellites on.
    @ViewBuilder
    private func satelliteLine(watch: SkyWatch, best: VisibleSatellite?, hasSite: Bool) -> some View {
        if !showSatellites || frame != nil || Self.stagedFrame != nil {
            EmptyView()
        } else if !hasSite {
            VStack(alignment: .leading, spacing: 8) {
                Text(locationNote ?? "To show the satellites overhead, StarDash needs to know roughly where the dish is. Use this Mac's location, type it in Settings, or let the dish share its own GPS: in the Starlink app, allow location access on the local network under advanced settings.")
                    .font(.system(size: 12)).foregroundStyle(locationNote == nil ? .white.opacity(0.55) : Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330, alignment: .leading)
                Button(locating ? "Finding this Mac…" : "Use this Mac's location") {
                    locationNote = nil
                    locating = true
                    MacLocation.shared.find { result in
                        locating = false
                        switch result {
                        case .success(let c): Settings.shared.setSite(latitude: c.latitude, longitude: c.longitude)
                        case .failure(let error): locationNote = error.localizedDescription + " Or type the dish's rough location in Settings."
                        }
                    }
                }
                .buttonStyle(QuietButton())
                .disabled(locating)
            }
            .padding(.top, 6)
        } else if watch.satellites.isEmpty {
            Text(watch.error.map { "Couldn't load satellite orbits: \($0)" } ?? "Loading satellite orbits…")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                .allowsHitTesting(false)
        } else {
            let serving = watch.satellites.filter { $0.elevation >= SkyWatch.serviceElevation }.count
            (Text("\(serving) Starlink satellites in range").foregroundStyle(.white.opacity(0.8))
                + Text(best.map { " · best placed \($0.name), \(Int($0.elevation.rounded()))° up" } ?? "").foregroundStyle(.white.opacity(0.5)))
                .font(.system(size: 12))
                .monospacedDigit()
                .help("Worked out from public orbit data. The dish doesn't report which satellite it's using, so \"best placed\" is the one in clear sky nearest to where the dish faces.")
        }
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}

/// Floating label that follows the pointer's reading.
private struct SkyReadout: View {
    var azimuth: Double
    var elevation: Double
    var value: Float?

    var body: some View {
        let status = ObstructionMap.describe(value)
        HStack(spacing: 8) {
            Circle().fill(status.color).frame(width: 7, height: 7)
            Text(status.text).fontWeight(.semibold)
            Text(String(format: "%@ %.0f° · %.0f° above the horizon", Fmt.compass(azimuth), azimuth, elevation))
                .foregroundStyle(.white.opacity(0.6))
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.75), in: Pillow())
        .overlay(Pillow().strokeBorder(.white.opacity(0.15)))
    }
}

// MARK: - Radar

/// Top-down dotted plot, as if lying on your back under the dish.
struct RadarSky: View {
    var map: ObstructionMap?
    var alignment: Alignment?
    var sky = SkyOverlay()
    @State private var pointer: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) - 56
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let maxTheta = map?.maxTheta ?? 80
            ZStack {
                RadarDots(map: map, alignment: alignment, sky: sky)
                if let pointer, let hit = sky.nearest(to: pointer, project: { azimuth, elevation in
                    let f = (90 - elevation) / maxTheta
                    guard f <= 1 else { return nil }
                    let a = azimuth * .pi / 180
                    return CGPoint(x: center.x + sin(a) * side / 2 * CGFloat(f), y: center.y - cos(a) * side / 2 * CGFloat(f))
                }) {
                    // On a satellite: name it instead of reading the sky behind it.
                    Circle().strokeBorder(.white, lineWidth: 1.5).frame(width: 16, height: 16).position(hit.at)
                    SatelliteReadout(satellite: hit.satellite)
                        .position(x: min(max(hit.at.x, 190), geo.size.width - 190), y: max(16, hit.at.y - 30))
                } else if let pointer, let reading = reading(at: pointer, center: center, radius: side / 2, maxTheta: maxTheta) {
                    Circle().strokeBorder(.white, lineWidth: 1.5).frame(width: 16, height: 16).position(pointer)
                    SkyReadout(azimuth: reading.az, elevation: reading.el, value: map?.sample(azimuth: reading.az, elevation: reading.el))
                        .fixedSize()
                        .position(x: min(max(pointer.x, 150), geo.size.width - 150), y: max(16, pointer.y - 30))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): pointer = p
                case .ended: pointer = nil
                }
            }
        }
    }

    private func reading(at p: CGPoint, center: CGPoint, radius: CGFloat, maxTheta: Double) -> (az: Double, el: Double)? {
        let dx = Double(p.x - center.x), dy = Double(center.y - p.y)
        let r = (dx * dx + dy * dy).squareRoot() / Double(radius)
        guard r <= 1 else { return nil }
        var az = atan2(dx, dy) * 180 / .pi
        if az < 0 { az += 360 }
        return (az, 90 - r * maxTheta)
    }
}

struct RadarDots: View {
    var map: ObstructionMap?
    var alignment: Alignment?
    /// Small version for the dashboard: no labels, tighter margin.
    var compact = false
    var sky = SkyOverlay()
    /// Draws the chart as a night sky: stars, the Milky Way and a glow at the horizon, like the 3D view.
    var night = false

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height) - (compact ? 6 : 56)
            let radius = side / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxTheta = map?.maxTheta ?? 80

            func ring(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }

            if night {
                Self.drawNight(in: &context, center: c, radius: radius)
            } else {
                context.fill(ring(radius), with: .radialGradient(
                    Gradient(colors: [Palette.accent.opacity(0.10), .white.opacity(0.02)]), center: c, startRadius: 0, endRadius: radius))
            }

            if let map {
                let cell = side / CGFloat(map.cols)
                let dot = max(1.4, cell * 0.62)
                for row in 0..<map.rows {
                    for col in 0..<map.cols {
                        let v = map.snr[row * map.cols + col]
                        guard v >= 0 else { continue }
                        let x = c.x - radius + (CGFloat(col) + 0.5) * cell
                        let y = c.y - radius + (CGFloat(row) + 0.5) * cell
                        let blocked = v < 0.5
                        let d = blocked ? dot * 1.25 : dot
                        if night, blocked {
                            let g = d * 2.2
                            context.fill(Path(ellipseIn: CGRect(x: x - g, y: y - g, width: g * 2, height: g * 2)),
                                         with: .radialGradient(Gradient(colors: [Palette.bad.opacity(0.35), Palette.bad.opacity(0)]),
                                                               center: CGPoint(x: x, y: y), startRadius: 0, endRadius: g))
                        }
                        // At night the clear sky is a faint veil, so the stars show through.
                        context.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)),
                                     with: .color(blocked ? Palette.bad : Palette.accent.opacity(night ? 0.1 : 0.55)))
                    }
                }
            }

            // Elevation rings and compass.
            for elevation in [60.0, 30.0] {
                let r = radius * CGFloat((90 - elevation) / maxTheta)
                context.stroke(ring(r), with: .color(.white.opacity(0.14)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                if !compact {
                    context.draw(Text(String(format: "%.0f°", elevation)).font(.system(size: 9.5)).foregroundColor(.white.opacity(0.45)),
                                 at: CGPoint(x: c.x + 4, y: c.y - r - 7), anchor: .leading)
                }
            }
            context.stroke(ring(radius), with: .color(.white.opacity(0.25)), lineWidth: 1)
            for degrees in stride(from: 0.0, to: 360, by: compact ? 360 : 15) where !compact {
                let a = degrees * .pi / 180
                let major = degrees.truncatingRemainder(dividingBy: 90) == 0
                var tick = Path()
                tick.move(to: CGPoint(x: c.x + sin(a) * radius, y: c.y - cos(a) * radius))
                tick.addLine(to: CGPoint(x: c.x + sin(a) * (radius + (major ? 7 : 4)), y: c.y - cos(a) * (radius + (major ? 7 : 4))))
                context.stroke(tick, with: .color(.white.opacity(major ? 0.6 : 0.25)), lineWidth: 1)
            }
            for (label, degrees) in [("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)] where !compact {
                let a = degrees * .pi / 180
                context.draw(Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(label == "N" ? 0.95 : 0.5)),
                             at: CGPoint(x: c.x + sin(a) * (radius + 17), y: c.y - cos(a) * (radius + 17)))
            }

            var sky = sky
            sky.night = night
            sky.draw(in: &context, compact: compact, width: size.width) { azimuth, elevation in
                let f = (90 - elevation) / maxTheta
                guard f <= 1 else { return nil }
                let a = azimuth * .pi / 180
                return CGPoint(x: c.x + sin(a) * radius * CGFloat(f), y: c.y - cos(a) * radius * CGFloat(f))
            }

            context.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(.white.opacity(0.7)))
        }
    }

    /// Deep blue at the zenith fading to black, a band of Milky Way, seeded stars and a cool glow on the horizon ring.
    static func drawNight(in context: inout GraphicsContext, center c: CGPoint, radius: CGFloat) {
        let disc = Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        context.fill(disc, with: .radialGradient(
            Gradient(stops: [.init(color: Color(red: 0.07, green: 0.09, blue: 0.16), location: 0),
                             .init(color: Color(red: 0.03, green: 0.04, blue: 0.08), location: 0.7),
                             .init(color: Color(red: 0.10, green: 0.14, blue: 0.24), location: 1)]),
            center: c, startRadius: 0, endRadius: radius))
        context.drawLayer { layer in
            layer.clip(to: disc)
            // The Milky Way: a soft, tilted band across the sky.
            layer.translateBy(x: c.x, y: c.y)
            layer.rotate(by: .degrees(-32))
            let band = CGRect(x: -radius * 1.2, y: -radius * 0.26, width: radius * 2.4, height: radius * 0.52)
            layer.fill(Path(ellipseIn: band), with: .radialGradient(
                Gradient(colors: [Color(red: 0.75, green: 0.8, blue: 1).opacity(0.2), .clear]),
                center: .zero, startRadius: 0, endRadius: radius * 0.9))
            layer.rotate(by: .degrees(32))
            layer.translateBy(x: -c.x, y: -c.y)
            var rng = SeededRandom(seed: 7)
            for _ in 0..<Int(radius * 3) {
                let a = Double(rng.next()) * 2 * .pi
                let r = sqrt(Double(rng.next())) * Double(radius)
                let p = CGPoint(x: c.x + CGFloat(cos(a) * r), y: c.y + CGFloat(sin(a) * r))
                let b = Double(rng.next())
                let size = 0.5 + CGFloat(b * b) * 1.3
                layer.fill(Path(ellipseIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)),
                           with: .color(Color(red: 0.85, green: 0.9, blue: 1).opacity(0.25 + b * 0.6)))
            }
        }
        context.stroke(disc, with: .color(Color(red: 0.55, green: 0.65, blue: 1).opacity(0.28)), lineWidth: 2)
    }
}

// MARK: - Horizon

/// The sky unrolled into a strip: compass direction across, height above the horizon up.
struct HorizonSky: View {
    var map: ObstructionMap?
    var alignment: Alignment?
    var sky = SkyOverlay()
    @State private var pointer: CGPoint?

    static let inset = EdgeInsets(top: 8, leading: 34, bottom: 26, trailing: 8)

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: Self.inset.leading, y: Self.inset.top,
                              width: geo.size.width - Self.inset.leading - Self.inset.trailing,
                              height: geo.size.height - Self.inset.top - Self.inset.bottom)
            let low = 90 - (map?.maxTheta ?? 80)
            ZStack {
                HorizonDots(map: map, alignment: alignment, sky: sky)
                if let pointer, let hit = sky.nearest(to: pointer, project: { azimuth, elevation in
                    guard elevation >= low else { return nil }
                    return CGPoint(x: plot.minX + plot.width * CGFloat(azimuth / 360),
                                   y: plot.minY + plot.height * CGFloat((90 - elevation) / (90 - low)))
                }) {
                    Circle().strokeBorder(.white, lineWidth: 1.5).frame(width: 16, height: 16).position(hit.at)
                    SatelliteReadout(satellite: hit.satellite)
                        .position(x: min(max(hit.at.x, 190), geo.size.width - 190), y: max(16, hit.at.y - 30))
                } else if let pointer, plot.contains(pointer) {
                    let az = Double((pointer.x - plot.minX) / plot.width) * 360
                    let el = 90 - Double((pointer.y - plot.minY) / plot.height) * (90 - low)
                    Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: plot.height).position(x: pointer.x, y: plot.midY)
                    Circle().strokeBorder(.white, lineWidth: 1.5).frame(width: 14, height: 14).position(pointer)
                    SkyReadout(azimuth: az, elevation: el, value: map?.sample(azimuth: az, elevation: el))
                        .fixedSize()
                        .position(x: min(max(pointer.x, 150), geo.size.width - 150), y: max(16, pointer.y - 28))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): pointer = p
                case .ended: pointer = nil
                }
            }
        }
    }
}

private struct HorizonDots: View {
    var map: ObstructionMap?
    var alignment: Alignment?
    var sky = SkyOverlay()

    var body: some View {
        Canvas { context, size in
            let inset = HorizonSky.inset
            let plot = CGRect(x: inset.leading, y: inset.top, width: size.width - inset.leading - inset.trailing,
                              height: size.height - inset.top - inset.bottom)
            let low = 90 - (map?.maxTheta ?? 80)
            let range = 90 - low

            func x(_ azimuth: Double) -> CGFloat { plot.minX + plot.width * CGFloat(azimuth / 360) }
            func y(_ elevation: Double) -> CGFloat { plot.minY + plot.height * CGFloat((90 - elevation) / range) }

            let frame = Path(roundedRect: plot, cornerRadius: Theme.r(10))
            context.fill(frame, with: .linearGradient(
                Gradient(colors: [Palette.accent.opacity(0.10), .white.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))

            if let map {
                let azStep = 4.0, elStep = 1.5
                let dot = max(1.6, min(plot.width / CGFloat(360 / azStep), plot.height / CGFloat(range / elStep)) * 0.55)
                for azimuth in stride(from: azStep / 2, to: 360, by: azStep) {
                    for elevation in stride(from: low + elStep / 2, to: 90, by: elStep) {
                        guard let v = map.sample(azimuth: azimuth, elevation: elevation), v >= 0 else { continue }
                        let blocked = v < 0.5
                        let d = blocked ? dot * 1.5 : dot
                        context.fill(Path(ellipseIn: CGRect(x: x(azimuth) - d / 2, y: y(elevation) - d / 2, width: d, height: d)),
                                     with: .color(blocked ? Palette.bad : Palette.accent.opacity(0.55)))
                    }
                }
            }

            for elevation in [30.0, 60.0] {
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y(elevation)))
                line.addLine(to: CGPoint(x: plot.maxX, y: y(elevation)))
                context.stroke(line, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
            for elevation in [low, 30.0, 60.0, 90.0] {
                context.draw(Text(String(format: "%.0f°", elevation)).font(.system(size: 10)).foregroundColor(.white.opacity(0.45)),
                             at: CGPoint(x: plot.minX - 6, y: y(elevation)), anchor: .trailing)
            }
            for (i, label) in ["N", "NE", "E", "SE", "S", "SW", "W", "NW", "N"].enumerated() {
                let azimuth = Double(i) * 45
                if i > 0, i < 8 {
                    var line = Path()
                    line.move(to: CGPoint(x: x(azimuth), y: plot.minY))
                    line.addLine(to: CGPoint(x: x(azimuth), y: plot.maxY))
                    context.stroke(line, with: .color(.white.opacity(i % 2 == 0 ? 0.10 : 0.05)), lineWidth: 1)
                }
                context.draw(Text(label).font(.system(size: 10.5, weight: i % 2 == 0 ? .semibold : .regular))
                    .foregroundColor(.white.opacity(i % 2 == 0 ? 0.75 : 0.4)),
                             at: CGPoint(x: x(azimuth), y: plot.maxY + 13))
            }
            context.stroke(frame, with: .color(.white.opacity(0.14)), lineWidth: 1)

            sky.draw(in: &context, compact: false) { azimuth, elevation in
                elevation >= low ? CGPoint(x: x(azimuth), y: y(elevation)) : nil
            }
        }
    }
}
