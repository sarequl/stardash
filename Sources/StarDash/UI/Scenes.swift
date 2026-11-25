import SceneKit
import SwiftUI

// MARK: - Shared helpers

enum SceneKitHelpers {
    static func points(_ vertices: [SCNVector3], color: NSColor, size: CGFloat) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: (0..<Int32(vertices.count)).map { $0 }, primitiveType: .point)
        element.pointSize = size
        element.minimumPointScreenSpaceRadius = size * 0.5
        element.maximumPointScreenSpaceRadius = size
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial = flat(color)
        return geometry
    }

    static func polyline(_ vertices: [SCNVector3], color: NSColor, closed: Bool = false) -> SCNGeometry {
        var indices: [Int32] = []
        for i in 0..<(vertices.count - 1) { indices += [Int32(i), Int32(i + 1)] }
        if closed, vertices.count > 2 { indices += [Int32(vertices.count - 1), 0] }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .line)]
        )
        geometry.firstMaterial = flat(color)
        return geometry
    }

    static func flat(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.isDoubleSided = true
        return m
    }

    static func glow(_ color: NSColor) -> SCNMaterial {
        let m = flat(color)
        m.blendMode = .add
        m.writesToDepthBuffer = false
        return m
    }

    /// Unit vector for a compass azimuth and elevation in a scene where +Y is up and -Z is north.
    static func skyDirection(azimuth: Double, elevation: Double) -> simd_float3 {
        let az = Float(azimuth * .pi / 180), el = Float(elevation * .pi / 180)
        return simd_float3(cos(el) * sin(az), sin(el), -cos(el) * cos(az))
    }

    static func label(_ text: String, color: NSColor, size: CGFloat) -> SCNNode {
        let font = NSFont.systemFont(ofSize: 44, weight: .bold)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let bounds = string.size()
        let image = NSImage(size: NSSize(width: bounds.width + 8, height: bounds.height + 8), flipped: false) { _ in
            string.draw(at: NSPoint(x: 4, y: 4))
            return true
        }
        let plane = SCNPlane(width: size * image.size.width / image.size.height, height: size)
        plane.firstMaterial = flat(.white)
        plane.firstMaterial?.diffuse.contents = image
        let node = SCNNode(geometry: plane)
        node.constraints = [SCNBillboardConstraint()]
        return node
    }

    static func makeView(scene: SCNScene, camera: SCNNode) -> OrbitView {
        let view = OrbitView()
        view.scene = scene
        view.pointOfView = camera
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = false
        return view
    }
}

// MARK: - Orbit control

/// SCNView with its own orbit handling. The stock camera controller drifts, rolls and lets the
/// scene tumble; this one keeps the horizon level, clamps the tilt, and coasts to a stop.
/// Nothing moves unless the user moves it. Double-click returns to the starting view.
final class OrbitView: SCNView {
    var zoomEnabled = true
    private var target = simd_float3(0, 0, 0)
    private var yaw: Float = 0
    private var pitch: Float = 0.3
    private var distance: Float = 3
    private var pitchRange: ClosedRange<Float> = -1...1
    private var distanceRange: ClosedRange<Float> = 2...6
    private var home: (yaw: Float, pitch: Float, distance: Float) = (0, 0.3, 3)
    private var velocity = simd_float2(0, 0)
    private var goingHome = false
    private var coast: Timer?

    func configure(target: simd_float3, yaw: Float, pitch: Float, distance: Float,
                   pitchRange: ClosedRange<Float>, distanceRange: ClosedRange<Float>) {
        self.target = target
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
        self.pitchRange = pitchRange
        self.distanceRange = distanceRange
        home = (yaw, pitch, distance)
        apply()
    }

    private func apply() {
        pitch = min(max(pitch, pitchRange.lowerBound), pitchRange.upperBound)
        distance = min(max(distance, distanceRange.lowerBound), distanceRange.upperBound)
        guard let camera = pointOfView else { return }
        let offset = simd_float3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
        camera.simdPosition = target + offset
        camera.simdLook(at: target, up: [0, 1, 0], localFront: [0, 0, -1])
    }

    // Dragging the scene must never drag the window.
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    /// Called with the pointer's place in the view as it moves, and nil when it leaves.
    var onHover: ((CGPoint?) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        stopCoasting()
        if event.clickCount == 2 {
            goingHome = true
            startCoasting()
            return
        }
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        // Grab-and-turn: the scene follows the pointer.
        let dx = Float(event.deltaX) * 0.0075, dy = Float(event.deltaY) * 0.0075
        yaw -= dx
        pitch += dy
        velocity = simd_float2(-dx, dy)
        apply()
    }

    override func mouseUp(with event: NSEvent) {
        guard event.clickCount < 2 else { return }
        NSCursor.pop()
        if simd_length(velocity) > 0.004 { startCoasting() } else { velocity = .zero }
    }

    override func scrollWheel(with event: NSEvent) {
        guard zoomEnabled else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        let delta = Float(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.004 : event.scrollingDeltaY * 0.04)
        distance *= exp(-delta)
        apply()
    }

    override func magnify(with event: NSEvent) {
        guard zoomEnabled else { return }
        distance *= 1 - Float(event.magnification)
        apply()
    }

    private func startCoasting() {
        coast?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        coast = timer
    }

    private func stopCoasting() {
        coast?.invalidate()
        coast = nil
        velocity = .zero
        goingHome = false
    }

    private func step() {
        if goingHome {
            // Take the short way round on yaw.
            var dyaw = (home.yaw - yaw).truncatingRemainder(dividingBy: 2 * .pi)
            if dyaw > .pi { dyaw -= 2 * .pi }
            if dyaw < -.pi { dyaw += 2 * .pi }
            yaw += dyaw * 0.16
            pitch += (home.pitch - pitch) * 0.16
            distance += (home.distance - distance) * 0.16
            apply()
            if abs(dyaw) < 0.002, abs(home.pitch - pitch) < 0.002, abs(home.distance - distance) < 0.004 { stopCoasting() }
            return
        }
        yaw += velocity.x
        pitch += velocity.y
        velocity *= 0.92
        apply()
        if simd_length(velocity) < 0.0004 { stopCoasting() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopCoasting() }
    }
}

// MARK: - Globe

/// Dotted Earth centered on the dish, with the constellation shell and the dish's beam.
/// Satellite positions are illustrative: the shell geometry is real (53° planes), the timing and altitude are not.
@MainActor
final class GlobeScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let earth = SCNNode()
    private let marker = SCNNode()
    private let beam = SCNNode()
    private var placed: String?
    private static let shell: Float = 1.16
    /// The stand-in constellation, shown until real orbits are loaded.
    private var standIn: [SCNNode] = []
    private let constellation = SCNNode()

    init() {
        let cam = SCNCamera()
        cam.fieldOfView = 34
        cam.zNear = 0.1
        cam.zFar = 50
        camera.camera = cam
        scene.rootNode.addChildNode(camera)

        let sway = SCNNode()
        scene.rootNode.addChildNode(sway)
        sway.addChildNode(earth)

        buildEarth()
        buildConstellation()
        buildStars()
        earth.addChildNode(marker)
        earth.addChildNode(beam)
    }

    private func buildEarth() {
        let sphere = SCNSphere(radius: 0.994)
        sphere.segmentCount = 96
        let surface = SCNMaterial()
        surface.lightingModel = .constant
        surface.diffuse.contents = NSColor(red: 0.015, green: 0.02, blue: 0.035, alpha: 1)
        // Rim light: brightens where the surface turns away from the camera.
        surface.shaderModifiers = [.fragment: """
        float rim = 1.0 - max(dot(normalize(_surface.view), normalize(_surface.normal)), 0.0);
        _output.color.rgb += vec3(0.22, 0.48, 1.0) * pow(rim, 4.2) * 0.65;
        """]
        sphere.firstMaterial = surface
        earth.addChildNode(SCNNode(geometry: sphere))

        let halo = SCNSphere(radius: 1.2)
        halo.segmentCount = 64
        let haze = SCNMaterial()
        haze.lightingModel = .constant
        haze.diffuse.contents = NSColor.black
        haze.cullMode = .front
        haze.blendMode = .add
        haze.writesToDepthBuffer = false
        haze.shaderModifiers = [.fragment: """
        float facing = abs(dot(normalize(_surface.view), normalize(_surface.normal)));
        float a = pow(facing, 5.0) * 0.55;
        _output.color = vec4(vec3(0.16, 0.40, 1.0) * a, a);
        """]
        halo.firstMaterial = haze
        earth.addChildNode(SCNNode(geometry: halo))

        // One dot per land cell on an equal-area-ish grid, so the poles don't clump.
        guard let mask = Data(base64Encoded: GlobeData.landBase64) else { return }
        var dots: [SCNVector3] = []
        var lat = -88.0
        while lat <= 88 {
            let step = 1.6 / max(cos(lat * .pi / 180), 0.08)
            var lon = -180.0
            while lon < 180 {
                let x = min(GlobeData.width - 1, Int(lon + 180)), y = min(GlobeData.height - 1, Int(90 - lat))
                let bit = y * GlobeData.width + x
                if mask[bit / 8] & (1 << UInt8(bit % 8)) != 0 { dots.append(SCNVector3(Self.position(lat: lat, lon: lon, radius: 1))) }
                lon += step
            }
            lat += 1.6
        }
        earth.addChildNode(SCNNode(geometry: SceneKitHelpers.points(dots, color: NSColor(white: 1, alpha: 0.82), size: 2.6)))
    }

    private func buildConstellation() {
        let planes = 22, perPlane = 16
        for p in 0..<planes {
            let plane = SCNNode()
            let raan = Float(p) / Float(planes) * 2 * .pi
            plane.simdOrientation = simd_quatf(angle: raan, axis: [0, 1, 0]) * simd_quatf(angle: 53 * .pi / 180, axis: [0, 0, 1])
            earth.addChildNode(plane)
            standIn.append(plane)

            // Faint orbit track so the shell reads as planes, not noise.
            let track = stride(from: 0.0, to: 360.0, by: 3).map { deg -> SCNVector3 in
                let a = Float(deg * .pi / 180)
                return SCNVector3(Self.shell * cos(a), 0, Self.shell * sin(a))
            }
            plane.addChildNode(SCNNode(geometry: SceneKitHelpers.polyline(track, color: NSColor(red: 0.45, green: 0.68, blue: 1, alpha: 0.10), closed: true)))

            let ring = SCNNode()
            var sats: [SCNVector3] = []
            for s in 0..<perPlane {
                let a = (Float(s) + Float(p % 2) * 0.5) / Float(perPlane) * 2 * .pi
                sats.append(SCNVector3(Self.shell * cos(a), 0, Self.shell * sin(a)))
            }
            ring.geometry = SceneKitHelpers.points(sats, color: NSColor(red: 0.80, green: 0.92, blue: 1, alpha: 1), size: 3.6)
            ring.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 150)))
            plane.addChildNode(ring)
        }
    }

    /// Draws the real constellation. Positions are Earth-fixed, in Earth radii.
    func update(shell positions: [SIMD3<Float>]) {
        guard !positions.isEmpty else { return }
        if constellation.parent == nil { earth.addChildNode(constellation) }
        standIn.forEach { $0.isHidden = true }
        let points = positions.map { p -> SCNVector3 in
            // Earth-fixed axes to the globe's: x toward 90° east, y toward the north pole, z toward 0° longitude.
            // Height above the surface is doubled so the shell stands clear of the globe at this size.
            let radius = simd_length(p)
            let lifted = 1 + (radius - 1) * 2
            return SCNVector3(simd_float3(p.y, p.z, p.x) / radius * lifted)
        }
        // Smaller and bluer than the land dots, so ten thousand of them don't drown the continents.
        constellation.geometry = SceneKitHelpers.points(points, color: NSColor(red: 0.50, green: 0.72, blue: 1, alpha: 0.6), size: 1.3)
    }

    private func buildStars() {
        var generator = SystemRandomNumberGenerator()
        var stars: [SCNVector3] = []
        for _ in 0..<420 {
            let u = Float.random(in: -1...1, using: &generator), t = Float.random(in: 0..<(2 * .pi), using: &generator)
            let r = (1 - u * u).squareRoot()
            stars.append(SCNVector3(r * cos(t) * 18, u * 18, r * sin(t) * 18))
        }
        scene.rootNode.addChildNode(SCNNode(geometry: SceneKitHelpers.points(stars, color: NSColor(white: 1, alpha: 0.35), size: 1.4)))
    }

    static func position(lat: Double, lon: Double, radius: Float) -> simd_float3 {
        let la = Float(lat * .pi / 180), lo = Float(lon * .pi / 180)
        return simd_float3(cos(la) * sin(lo), sin(la), cos(la) * cos(lo)) * radius
    }

    func update(country: String?, azimuth: Double?, elevation: Double?, color: NSColor, online: Bool) {
        guard let country, let (lat, lon) = GlobeData.centroids[country.uppercased()] else {
            marker.isHidden = true
            beam.isHidden = true
            return
        }
        let key = "\(country)-\(Int(azimuth ?? 0))-\(Int(elevation ?? 0))-\(online)-\(color.hashValue)"
        guard key != placed else { return }
        placed = key

        // Turn the globe so the dish sits just below the middle of the view.
        let la = Float(lat * .pi / 180) * 0.82, lo = Float(lon * .pi / 180)
        earth.simdOrientation = simd_quatf(angle: la, axis: [1, 0, 0]) * simd_quatf(angle: -lo, axis: [0, 1, 0])

        let p = Self.position(lat: lat, lon: lon, radius: 1.002)
        let up = simd_normalize(p)

        marker.isHidden = false
        marker.childNodes.forEach { $0.removeFromParentNode() }
        marker.simdPosition = p
        marker.simdOrientation = simd_quatf(from: [0, 1, 0], to: up)
        let core = SCNSphere(radius: 0.013)
        core.firstMaterial = SceneKitHelpers.flat(color)
        marker.addChildNode(SCNNode(geometry: core))
        for delay in [0.0, 1.1] {
            let ring = SCNTorus(ringRadius: 0.03, pipeRadius: 0.0022)
            ring.firstMaterial = SceneKitHelpers.glow(color)
            let node = SCNNode(geometry: ring)
            node.opacity = 0
            let pulse = SCNAction.sequence([
                .group([.scale(to: 0.6, duration: 0), .fadeOpacity(to: 0.95, duration: 0)]),
                .group([.scale(to: 4.2, duration: 2.2), .fadeOut(duration: 2.2)]),
            ])
            node.runAction(.sequence([.wait(duration: delay), .repeatForever(pulse)]))
            marker.addChildNode(node)
        }

        beam.childNodes.forEach { $0.removeFromParentNode() }
        beam.isHidden = !online
        guard online, let azimuth, let elevation else { return }
        // Local east/north/up at the dish, then the boresight in that frame.
        let east = simd_normalize(simd_cross(simd_float3(0, 1, 0), up))
        let north = simd_cross(up, east)
        let az = Float(azimuth * .pi / 180), el = Float(max(elevation, 25) * .pi / 180)
        let dir = simd_normalize(cos(el) * (sin(az) * east + cos(az) * north) + sin(el) * up)
        // Distance along the boresight until it reaches the shell.
        let b = simd_dot(p, dir)
        let length = -b + (b * b - simd_length_squared(p) + Self.shell * Self.shell).squareRoot()

        let shaft = SCNCylinder(radius: 0.0035, height: CGFloat(length))
        shaft.firstMaterial = SceneKitHelpers.glow(color.withAlphaComponent(0.9))
        let shaftNode = SCNNode(geometry: shaft)
        shaftNode.simdPosition = p + dir * length / 2
        shaftNode.simdOrientation = simd_quatf(from: [0, 1, 0], to: dir)
        beam.addChildNode(shaftNode)

        let target = SCNSphere(radius: 0.02)
        target.firstMaterial = SceneKitHelpers.glow(color)
        let targetNode = SCNNode(geometry: target)
        targetNode.simdPosition = p + dir * length
        targetNode.runAction(.repeatForever(.sequence([.scale(to: 1.5, duration: 0.9), .scale(to: 0.9, duration: 0.9)])))
        beam.addChildNode(targetNode)
    }
}

struct GlobeView: NSViewRepresentable {
    var country: String?
    var azimuth: Double?
    var elevation: Double?
    var color: Color
    var online: Bool
    var shell: [SIMD3<Float>] = []

    func makeCoordinator() -> GlobeScene { GlobeScene() }

    func makeNSView(context: Context) -> OrbitView {
        let view = SceneKitHelpers.makeView(scene: context.coordinator.scene, camera: context.coordinator.camera)
        view.configure(target: [0, 0.06, 0], yaw: 0, pitch: 0.06, distance: 3.5,
                       pitchRange: -1.1...1.1, distanceRange: 3.5...3.5)
        // Leave scrolling to the page: the globe sits inside a scroll view.
        view.zoomEnabled = false
        return view
    }

    func updateNSView(_ view: OrbitView, context: Context) {
        context.coordinator.update(country: country, azimuth: azimuth, elevation: elevation, color: NSColor(color), online: online)
        context.coordinator.update(shell: shell)
    }
}

// MARK: - Sky dome

/// The obstruction map wrapped onto the sky hemisphere above a model of the dish. Drag to orbit.
@MainActor
final class DomeScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let turntable = SCNNode()
    private let domeMaterial = SCNMaterial()
    private let dish = SCNNode()
    private let halo = SCNNode()
    private var maxTheta = 80.0
    private var domeNode: SCNNode?
    private var shellNode: SCNNode?
    /// The sky map, its glass and its grid, so they can be hidden together.
    private let mapLayer = SCNNode()
    private let satellites = SCNNode()
    private var satellitePool: [SCNNode] = []
    private let link = SCNNode()
    private let linkMaterial = SCNMaterial()
    /// How busy each direction looks, 0...1, eased so the beam doesn't jump every poll.
    private var rxLevel: Double = 0
    private var txLevel: Double = 0
    private var shown: [VisibleSatellite] = []
    private var bestID: Int?
    private var hoveredID: Int?
    private var hoverLabel: SCNNode?
    private var bestLabel: SCNNode?
    private var bestName: String?

    init() {
        let cam = SCNCamera()
        cam.fieldOfView = 38
        cam.zNear = 0.05
        cam.zFar = 50
        camera.camera = cam
        scene.rootNode.addChildNode(camera)
        scene.rootNode.addChildNode(turntable)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 260
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
        let key = SCNLight()
        key.type = .directional
        key.intensity = 900
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-1.0, 0.6, 0)
        scene.rootNode.addChildNode(keyNode)
        // A cool light from behind, so the panel's edges catch a rim.
        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = 600
        rim.color = NSColor(white: 0.85, alpha: 1)
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.eulerAngles = SCNVector3(-0.4, .pi, 0)
        scene.rootNode.addChildNode(rimNode)

        turntable.addChildNode(mapLayer)
        buildSpace()
        buildGround()
        buildGrid()
        buildDish()
        rebuildDome()
        turntable.addChildNode(satellites)
        buildHalo()
        buildBeam()
    }

    /// The link from the dish to the satellite it's most likely talking to, drawn as traffic: blue packets
    /// coming down, purple ones going up, over a faint gold line. Busier directions get longer, brighter packets.
    private func buildBeam() {
        let tube = SCNCylinder(radius: 0.016, height: 1)
        tube.radialSegmentCount = 32
        func vec(_ color: Color) -> String {
            let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
            return "vec3(\(c.redComponent), \(c.greenComponent), \(c.blueComponent))"
        }
        let material = linkMaterial
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        // Brightest where the tube faces the camera, so from any angle it reads as a line of light.
        // The cylinder's texture runs 0 at the satellite end to 1 at the dish.
        material.shaderModifiers = [.fragment: """
        uniform float rxLevel;
        uniform float txLevel;
        uniform float motion;
        #pragma body
        float f = abs(dot(normalize(_surface.view), normalize(_surface.normal)));
        float core = pow(f, 22.0);
        float glow = pow(f, 4.0) * 0.28;
        float body = pow(f, 3.0);
        float s = 1.0 - _surface.diffuseTexcoord.y;
        float ends = smoothstep(0.0, 0.06, s) * smoothstep(0.0, 0.03, 1.0 - s);
        float clock = u_time * motion * 3.5;
        float count = 7.0;

        // Down: each packet's bright head leads toward the dish, with a tail fading behind it.
        float rp = fract(s * count + clock);
        float rx = smoothstep(0.0, 0.03, rp) * (1.0 - smoothstep(0.0, mix(0.08, 0.35, rxLevel), rp)) * mix(0.4, 1.0, rxLevel);
        // Up: the same, heading for the satellite, half a spacing out of step.
        float tp = 1.0 - fract(s * count - clock + 0.5);
        float tx = smoothstep(0.0, 0.03, tp) * (1.0 - smoothstep(0.0, mix(0.08, 0.35, txLevel), tp)) * mix(0.4, 1.0, txLevel) * 1.3;

        vec3 col = \(vec(Palette.link)) * (core * 0.22 + glow * 0.3)
                 + mix(\(vec(Palette.down)), vec3(1.0), core * 0.6) * rx * (body + core)
                 + mix(\(vec(Palette.up)), vec3(1.0), core * 0.6) * tx * (body + core);
        col *= ends;
        _output.color = vec4(col, clamp(max(col.r, max(col.g, col.b)), 0.0, 1.0));
        """]
        tube.firstMaterial = material
        link.geometry = tube
        link.renderingOrder = 21
        link.isHidden = true
        setTraffic(down: nil, up: nil)
        turntable.addChildNode(link)
    }

    /// Sets how busy the link looks from the dish's live throughput, in bits per second.
    /// On a log scale: 10 kbps is idle, 1 Gbps is flat out.
    func setTraffic(down: Double?, up: Double?) {
        func level(_ bps: Double?) -> Double {
            guard let bps, bps.isFinite else { return 0 }
            return min(1, max(0, log10(max(bps, 1e4) / 1e4) / 5))
        }
        rxLevel = (rxLevel + level(down)) / 2
        txLevel = (txLevel + level(up)) / 2
        linkMaterial.setValue(NSNumber(value: rxLevel), forKey: "rxLevel")
        linkMaterial.setValue(NSNumber(value: txLevel), forKey: "txLevel")
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        linkMaterial.setValue(NSNumber(value: still ? 0.0 : 1.0), forKey: "motion")
    }

    /// A soft glow that breathes behind the linked satellite.
    private func buildHalo() {
        let side: CGFloat = 128
        let color = NSColor(Palette.link)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSGradient(colors: [color.withAlphaComponent(0.75), color.withAlphaComponent(0.18), color.withAlphaComponent(0)],
                       atLocations: [0, 0.45, 1], colorSpace: .sRGB)?.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: .zero)
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: side * 0.27, dy: side * 0.27))
            ring.lineWidth = side * 0.025
            color.withAlphaComponent(0.9).setStroke()
            ring.stroke()
            return true
        }
        let plane = SCNPlane(width: 0.24, height: 0.24)
        let material = SceneKitHelpers.glow(.white)
        material.diffuse.contents = image
        material.readsFromDepthBuffer = false
        plane.firstMaterial = material
        halo.geometry = plane
        halo.renderingOrder = 19
        halo.constraints = [SCNBillboardConstraint()]
        halo.isHidden = true
        halo.runAction(.repeatForever(.sequence([
            .group([.scale(to: 1.15, duration: 1.1), .fadeOpacity(to: 0.65, duration: 1.1)]),
            .group([.scale(to: 0.9, duration: 1.1), .fadeOpacity(to: 1, duration: 1.1)]),
        ])))
        turntable.addChildNode(halo)
    }

    /// Puts a craft in the sky for each satellite, in its real direction from the dish.
    func update(sky: SkyOverlay) {
        while satellitePool.count < sky.satellites.count {
            let node = SCNNode(geometry: Self.craft)
            node.renderingOrder = 20
            node.constraints = [SCNBillboardConstraint()]
            satellites.addChildNode(node)
            satellitePool.append(node)
        }
        shown = sky.satellites
        bestID = sky.best
        if let hoveredID, !shown.contains(where: { $0.id == hoveredID }) { setHovered(nil) }
        var best: (simd_float3, String)?
        for (i, node) in satellitePool.enumerated() {
            guard i < sky.satellites.count else { node.isHidden = true; continue }
            let sat = sky.satellites[i]
            let inRange = sat.elevation >= SkyWatch.serviceElevation
            let p = Self.orbitPoint(azimuth: sat.azimuth, elevation: sat.elevation)
            node.isHidden = false
            node.simdPosition = p
            node.geometry = sat.id == sky.best ? Self.linkedCraft : Self.craft
            node.simdScale = simd_float3(repeating: Self.scale(sat, best: sky.best, hovered: hoveredID))
            if sat.id == hoveredID { hoverLabel?.simdPosition = p + Self.labelLift }
            node.opacity = inRange || sat.id == sky.best ? 1 : 0.45
            if sat.id == sky.best { best = (p, sat.name) }
        }
        if best?.1 != bestName {
            bestLabel?.removeFromParentNode()
            bestLabel = best.map { SceneKitHelpers.label($0.1, color: .white, size: 0.13) }
            bestLabel.map(turntable.addChildNode)
            bestName = best?.1
        }
        if let best { bestLabel?.simdPosition = best.0 + Self.labelLift * 1.3 }
        halo.isHidden = best == nil
        if let best { halo.simdPosition = best.0 }

        applyLink(best)
    }

    /// Names the satellite under the pointer. `point` is in the view's own coordinates.
    func hover(at point: CGPoint?, in view: SCNView) {
        guard let point else { setHovered(nil); return }
        var found: Int?
        var closest: CGFloat = 13
        for (i, node) in satellitePool.enumerated() where i < shown.count && !node.isHidden {
            let projected = view.projectPoint(node.worldPosition)
            // Behind the camera.
            guard projected.z < 1 else { continue }
            let d = hypot(CGFloat(projected.x) - point.x, CGFloat(projected.y) - point.y)
            if d < closest { closest = d; found = shown[i].id }
        }
        setHovered(found)
    }

    private func setHovered(_ id: Int?) {
        guard id != hoveredID else { return }
        hoveredID = id
        hoverLabel?.removeFromParentNode()
        hoverLabel = nil
        for (i, node) in satellitePool.enumerated() where i < shown.count {
            let sat = shown[i]
            let inRange = sat.elevation >= SkyWatch.serviceElevation
            node.simdScale = simd_float3(repeating: Self.scale(sat, best: bestID, hovered: id))
            // The best placed one already carries its name.
            if sat.id == id, sat.id != bestID {
                let label = SceneKitHelpers.label(String(format: "%@ · %.0f° up", sat.name, sat.elevation), color: .white, size: 0.12)
                label.simdPosition = node.simdPosition + Self.labelLift
                label.renderingOrder = 30
                turntable.addChildNode(label)
                hoverLabel = label
            }
        }
    }

    private func applyLink(_ best: (simd_float3, String)?) {
        guard let best else { link.isHidden = true; return }
        let from = simd_float3(0, 0.1, 0)
        let span = best.0 - from
        link.isHidden = false
        link.simdPosition = from + span / 2
        link.simdOrientation = simd_quatf(from: [0, 1, 0], to: simd_normalize(span))
        link.simdScale = [1, simd_length(span), 1]
    }

    /// The world around the dish: night sky on a far sphere, dark land running out to a hazy horizon,
    /// and a line of distant hills. All on the turntable, so it turns with the dome.
    private func buildSpace() {
        let sphere = SCNSphere(radius: 30)
        sphere.segmentCount = 72
        let stars = SceneKitHelpers.flat(.white)
        stars.diffuse.contents = Self.starTexture
        stars.diffuse.mipFilter = .linear
        stars.cullMode = .front
        stars.writesToDepthBuffer = false
        sphere.firstMaterial = stars
        let sky = SCNNode(geometry: sphere)
        sky.renderingOrder = -20
        turntable.addChildNode(sky)

        let land = SCNPlane(width: 56, height: 56)
        let landMaterial = SceneKitHelpers.flat(.white)
        landMaterial.diffuse.contents = Self.groundTexture
        landMaterial.diffuse.mipFilter = .linear
        landMaterial.writesToDepthBuffer = false
        land.firstMaterial = landMaterial
        let landNode = SCNNode(geometry: land)
        landNode.eulerAngles.x = -.pi / 2
        landNode.position.y = -0.004
        landNode.renderingOrder = -6
        turntable.addChildNode(landNode)

        let hills = SCNCylinder(radius: 26, height: 1.6)
        hills.radialSegmentCount = 128
        let ridge = SceneKitHelpers.flat(.white)
        ridge.diffuse.contents = Self.hillsTexture
        ridge.writesToDepthBuffer = false
        let none = SceneKitHelpers.flat(.clear)
        none.transparency = 0
        hills.materials = [ridge, none, none]
        let hillsNode = SCNNode(geometry: hills)
        hillsNode.position.y = 0.5
        hillsNode.renderingOrder = -5
        turntable.addChildNode(hillsNode)
    }

    /// Night haze at the horizon. The far ground fades into it and the sky rises out of it.
    private static let haze = (r: 0.075, g: 0.095, b: 0.14)

    /// Stars on an equirectangular map: thousands of points of mixed brightness and colour, and a denser,
    /// cloudy band for the Milky Way. Haze is laid over the bottom of the sky, so stars dim toward the
    /// horizon as they do through real air. Seeded, so it's the same sky every launch.
    private static let starTexture: CGImage? = {
        let w = 4096, h = 2048
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.004, green: 0.006, blue: 0.014, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // y = h/2 is the horizon; the zenith side is up.
        let horizon = CGFloat(h) / 2
        var rng = SeededRandom(seed: 0x5DA5)
        func point(lat: Double, lon: Double) -> CGPoint {
            CGPoint(x: CGFloat((lon + .pi) / (2 * .pi)) * CGFloat(w), y: horizon + CGFloat(lat / (.pi / 2)) * horizon)
        }
        // Anything near the left or right edge is drawn again across the seam, so the wrap doesn't show.
        func wrapped(_ p: CGPoint, _ r: CGFloat) -> [CGPoint] {
            var points = [p]
            if p.x < r { points.append(CGPoint(x: p.x + CGFloat(w), y: p.y)) }
            if p.x > CGFloat(w) - r { points.append(CGPoint(x: p.x - CGFloat(w), y: p.y)) }
            return points
        }
        func dot(_ p: CGPoint, _ r: CGFloat, _ color: CGColor) {
            ctx.setFillColor(color)
            for q in wrapped(p, r) { ctx.fillEllipse(in: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)) }
        }
        // The Milky Way: a great circle tilted across the sky. Soft clouds first, then a crowd of faint stars in them.
        let tilt = 1.05, node = 0.6
        func bandPoint(along t: Double, off: Double) -> (lat: Double, lon: Double) {
            // Point on the tilted circle, nudged off it by `off` radians.
            var x = cos(t), y = sin(t) * cos(tilt), z = sin(t) * sin(tilt)
            y += off * -sin(tilt) * 1; z += off * cos(tilt)
            let n = (x * x + y * y + z * z).squareRoot(); x /= n; y /= n; z /= n
            return (asin(z), atan2(y, x) + node - .pi)
        }
        for _ in 0..<4000 {
            let (lat, lon) = bandPoint(along: rng.next() * 2 * .pi, off: rng.gaussian() * 0.16)
            let p = point(lat: lat, lon: lon)
            let r = CGFloat(18 + rng.next() * 46)
            if let cloud = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                CGColor(red: 0.62, green: 0.68, blue: 0.85, alpha: 0.05), CGColor(red: 0.5, green: 0.55, blue: 0.75, alpha: 0)] as CFArray, locations: [0, 1]) {
                for q in wrapped(p, r) {
                    ctx.drawRadialGradient(cloud, startCenter: q, startRadius: 0, endCenter: q, endRadius: r, options: [])
                }
            }
        }
        for _ in 0..<16000 {
            let (lat, lon) = bandPoint(along: rng.next() * 2 * .pi, off: rng.gaussian() * 0.12)
            dot(point(lat: lat, lon: lon), 0.55, CGColor(red: 0.85, green: 0.88, blue: 1, alpha: 0.12 + rng.next() * 0.3))
        }
        // The general field. Mostly faint; a few bright ones with a halo; colours from blue-white to warm.
        let tints: [(CGFloat, CGFloat, CGFloat)] = [(0.75, 0.82, 1), (1, 1, 1), (1, 0.95, 0.85), (1, 0.85, 0.7)]
        for _ in 0..<12000 {
            let lat = asin(rng.next() * 2 - 1), lon = rng.next() * 2 * .pi - .pi
            let p = point(lat: lat, lon: lon)
            let b = pow(rng.next(), 5)
            let t = tints[Int(rng.next() * Double(tints.count)) % tints.count]
            let r = CGFloat(0.45 + b * 0.9)
            if b > 0.7 {
                dot(p, r * 2.4, CGColor(red: t.0, green: t.1, blue: t.2, alpha: 0.06))
            }
            dot(p, r, CGColor(red: t.0, green: t.1, blue: t.2, alpha: 0.18 + b * 0.82))
        }
        // Haze: solid below the horizon, thinning out over the first 35 degrees of sky.
        let hz = haze
        ctx.setFillColor(CGColor(red: hz.r, green: hz.g, blue: hz.b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: horizon))
        if let air = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: hz.r * 1.15, green: hz.g * 1.15, blue: hz.b * 1.15, alpha: 1),
            CGColor(red: hz.r, green: hz.g, blue: hz.b, alpha: 0.7),
            CGColor(red: hz.r * 0.6, green: hz.g * 0.6, blue: hz.b * 0.8, alpha: 0.25),
            CGColor(red: 0, green: 0, blue: 0.02, alpha: 0)] as CFArray, locations: [0, 0.04, 0.16, 0.4]) {
            ctx.drawLinearGradient(air, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: CGFloat(h)), options: [])
        }
        return ctx.makeImage()
    }()

    /// Dark land with faint patches, fading into the horizon haze with distance.
    private static let groundTexture: CGImage? = {
        let side = 2048
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let c = CGPoint(x: side / 2, y: side / 2)
        ctx.setFillColor(CGColor(red: 0.022, green: 0.025, blue: 0.03, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        var rng = SeededRandom(seed: 0x6E0)
        for _ in 0..<5000 {
            let p = CGPoint(x: rng.next() * Double(side), y: rng.next() * Double(side))
            let r = CGFloat(3 + rng.next() * 26)
            let shade = rng.next() < 0.5 ? 0.0 : 0.09
            ctx.setFillColor(CGColor(red: shade, green: shade * 1.05, blue: shade * 1.1, alpha: 0.05 + rng.next() * 0.05))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r * 0.7, width: r * 2, height: r * 1.4))
        }
        let hz = haze
        if let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: hz.r, green: hz.g, blue: hz.b, alpha: 0), CGColor(red: hz.r, green: hz.g, blue: hz.b, alpha: 0.35),
            CGColor(red: hz.r, green: hz.g, blue: hz.b, alpha: 0.85), CGColor(red: hz.r, green: hz.g, blue: hz.b, alpha: 1)] as CFArray,
            locations: [0.06, 0.3, 0.7, 0.95]) {
            ctx.drawRadialGradient(fade, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(side) / 2, options: [.drawsAfterEndLocation])
        }
        return ctx.makeImage()
    }()

    /// A ring of low hills on the horizon, dark against the haze.
    private static let hillsTexture: CGImage? = {
        let w = 4096, h = 256
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var rng = SeededRandom(seed: 0x4111)
        // Whole numbers of waves around the circle, so the ridge meets itself.
        let waves = (0..<9).map { k in (freq: Double([2, 3, 5, 7, 11, 17, 29, 47, 83][k]), amp: [0.3, 0.25, 0.2, 0.14, 0.09, 0.05, 0.03, 0.018, 0.01][k], phase: rng.next() * 2 * .pi) }
        let ground = 0.3 / 1.6 * Double(h)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        for x in stride(from: 0, through: w, by: 2) {
            let t = Double(x) / Double(w) * 2 * .pi
            var v = 0.0
            for wave in waves { v += wave.amp * sin(wave.freq * t + wave.phase) }
            let height = max(0.05, 0.4 + v * 1.4) * 0.9 / 1.6 * Double(h)
            path.addLine(to: CGPoint(x: Double(x), y: ground + height))
        }
        path.addLine(to: CGPoint(x: w, y: 0))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0.03, green: 0.037, blue: 0.052, alpha: 1))
        ctx.fillPath()
        return ctx.makeImage()
    }()

    private func buildGround() {
        // A pool of light on the ground, brightest under the dish and gone by the horizon.
        let floor = SCNPlane(width: 2.2, height: 2.2)
        let floorMaterial = SceneKitHelpers.flat(.white)
        floorMaterial.diffuse.contents = Self.radial(side: 512, stops: [(0, 0.05), (0.12, 0.022), (0.3, 0.006), (0.5, 0)])
        floorMaterial.writesToDepthBuffer = false
        floor.firstMaterial = floorMaterial
        let floorNode = SCNNode(geometry: floor)
        floorNode.eulerAngles.x = -.pi / 2
        floorNode.position.y = -0.002
        floorNode.renderingOrder = -2
        turntable.addChildNode(floorNode)

        // A soft contact shadow under the dish.
        let shadow = SCNPlane(width: 0.42, height: 0.42)
        let shadowMaterial = SceneKitHelpers.flat(.black)
        shadowMaterial.diffuse.contents = Self.radial(side: 128, stops: [(0, 0.7), (0.22, 0.35), (0.5, 0)], white: 0)
        shadowMaterial.writesToDepthBuffer = false
        shadow.firstMaterial = shadowMaterial
        let shadowNode = SCNNode(geometry: shadow)
        shadowNode.eulerAngles.x = -.pi / 2
        shadowNode.renderingOrder = -1
        turntable.addChildNode(shadowNode)

        for (text, az) in [("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)] {
            let color = text == "N" ? NSColor(Palette.bad) : NSColor(white: 1, alpha: 0.6)
            let label = SceneKitHelpers.label(text, color: color, size: 0.11)
            label.simdPosition = SceneKitHelpers.skyDirection(azimuth: az, elevation: 0) * 1.13 + simd_float3(0, 0.03, 0)
            turntable.addChildNode(label)
        }
    }

    private func buildGrid() {
        let faint = NSColor(white: 1, alpha: 0.07)
        for elevation in [0.0, 30.0, 60.0] {
            let ring = stride(from: 0.0, to: 360.0, by: 3).map {
                SCNVector3(SceneKitHelpers.skyDirection(azimuth: $0, elevation: elevation))
            }
            mapLayer.addChildNode(SCNNode(geometry: SceneKitHelpers.polyline(ring, color: elevation == 0 ? NSColor(white: 1, alpha: 0.22) : faint, closed: true)))
        }
        for azimuth in stride(from: 0.0, to: 360.0, by: 45) {
            let arc = stride(from: 0.0, through: 90.0, by: 3).map {
                SCNVector3(SceneKitHelpers.skyDirection(azimuth: azimuth, elevation: $0))
            }
            mapLayer.addChildNode(SCNNode(geometry: SceneKitHelpers.polyline(arc, color: faint)))
        }
    }

    private func buildDish() {
        let stand = SCNCylinder(radius: 0.012, height: 0.1)
        stand.firstMaterial?.diffuse.contents = NSColor(white: 0.35, alpha: 1)
        let standNode = SCNNode(geometry: stand)
        standNode.position.y = 0.05
        turntable.addChildNode(standNode)

        // The Mini is a flat slab, so a rounded box reads right. Its top face looks along the boresight.
        let panel = SCNBox(width: 0.2, height: 0.014, length: 0.26, chamferRadius: 0.006)
        let face = SCNMaterial()
        face.lightingModel = .physicallyBased
        face.diffuse.contents = NSColor(white: 0.86, alpha: 1)
        face.roughness.contents = 0.4
        face.metalness.contents = 0.0
        panel.materials = [face]
        dish.geometry = panel
        dish.position.y = 0.1
        turntable.addChildNode(dish)

    }

    /// Hemisphere mesh whose texture coordinates point straight into the dish's polar map image.
    private func rebuildDome() {
        domeNode?.removeFromParentNode()
        var vertices: [SCNVector3] = []
        var uvs: [CGPoint] = []
        var indices: [Int32] = []
        let azSteps = 72, elSteps = 30
        for e in 0...elSteps {
            let elevation = Double(e) / Double(elSteps) * 90
            // Radius in the polar image: zenith at the center, max theta at the edge.
            let r = (90 - elevation) / maxTheta
            for a in 0...azSteps {
                let azimuth = Double(a) / Double(azSteps) * 360
                vertices.append(SCNVector3(SceneKitHelpers.skyDirection(azimuth: azimuth, elevation: elevation)))
                let rad = azimuth * .pi / 180
                uvs.append(CGPoint(x: 0.5 + r * sin(rad) / 2, y: 0.5 - r * cos(rad) / 2))
            }
        }
        let row = Int32(azSteps + 1)
        for e in 0..<Int32(elSteps) {
            for a in 0..<Int32(azSteps) {
                let i = e * row + a
                indices += [i, i + 1, i + row, i + 1, i + row + 1, i + row]
            }
        }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: vertices), SCNGeometrySource(textureCoordinates: uvs)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
        domeMaterial.lightingModel = .constant
        domeMaterial.isDoubleSided = true
        domeMaterial.blendMode = .alpha
        domeMaterial.writesToDepthBuffer = false
        domeMaterial.diffuse.magnificationFilter = .linear
        domeMaterial.diffuse.mipFilter = .linear
        domeMaterial.diffuse.minificationFilter = .linear
        domeMaterial.diffuse.wrapS = .clampToBorder
        domeMaterial.diffuse.wrapT = .clampToBorder
        domeMaterial.diffuse.borderColor = NSColor.clear
        if domeMaterial.diffuse.contents == nil { domeMaterial.diffuse.contents = NSColor.clear }
        geometry.firstMaterial = domeMaterial
        let node = SCNNode(geometry: geometry)
        node.renderingOrder = 10
        mapLayer.addChildNode(node)
        domeNode = node

        // A faint glass edge, so the hemisphere reads as a shape even where nothing is mapped.
        shellNode?.removeFromParentNode()
        let glass = geometry.copy() as! SCNGeometry
        let shell = SceneKitHelpers.glow(.white)
        shell.readsFromDepthBuffer = false
        shell.cullMode = .back
        shell.shaderModifiers = [.fragment: """
        float edge = 1.0 - abs(dot(normalize(_surface.view), normalize(_surface.normal)));
        float a = pow(edge, 5.0) * 0.12;
        _output.color = vec4(vec3(a), a);
        """]
        glass.materials = [shell]
        let shellGeometryNode = SCNNode(geometry: glass)
        shellGeometryNode.renderingOrder = 9
        mapLayer.addChildNode(shellGeometryNode)
        shellNode = shellGeometryNode
    }

    func setMapVisible(_ visible: Bool) {
        mapLayer.isHidden = !visible
    }

    func update(map: ObstructionMap?, alignment: Alignment?) {
        if let map {
            if abs(map.maxTheta - maxTheta) > 0.5 {
                maxTheta = map.maxTheta
                rebuildDome()
            }
            domeMaterial.diffuse.contents = Self.skyTexture(map)
        }

        guard let az = alignment?.azimuth, let el = alignment?.elevation else { return }
        // Face normal along the boresight, long edge kept pointing "up the slope".
        dish.simdOrientation = simd_quatf(from: [0, 1, 0], to: SceneKitHelpers.skyDirection(azimuth: az, elevation: el))
    }

    /// Where a satellite is drawn: along its true direction from the dish, out to a flat ceiling high above it,
    /// the way the orbital shell looks from the ground. Overhead ones are close; low ones are far off and sit
    /// just over the horizon. Height isn't to scale.
    static let orbitHeight: Float = 2.3
    static func orbitPoint(azimuth: Double, elevation: Double) -> simd_float3 {
        let dir = SceneKitHelpers.skyDirection(azimuth: azimuth, elevation: elevation)
        return dir * min(18, orbitHeight / max(dir.y, 0.05))
    }
    private static let labelLift = simd_float3(0, 0.17, 0)

    /// Satellite sprites: one plain, one for the satellite the dish is most likely linked to.
    private static let craft = sprite(SatelliteGlyph.glint(color: NSColor(white: 0.92, alpha: 1)), side: 0.11)
    private static let linkedCraft = sprite(SatelliteGlyph.glint(color: NSColor(Palette.link)), side: 0.12)

    private static func sprite(_ image: NSImage, side: CGFloat) -> SCNPlane {
        let plane = SCNPlane(width: side, height: side)
        let material = SceneKitHelpers.flat(.white)
        material.diffuse.contents = image
        material.diffuse.mipFilter = .linear
        material.writesToDepthBuffer = false
        plane.firstMaterial = material
        // A satellite low behind the camera passes right by the lens. Closer than 4 units it
        // shrinks with distance, so it never looks bigger on screen than one 4 units away.
        plane.shaderModifiers = [.geometry: """
        float d = length((scn_node.modelViewTransform * float4(0.0, 0.0, 0.0, 1.0)).xyz);
        _geometry.position.xyz *= min(1.0, d / 4.0);
        """]
        return plane
    }

    /// The sky map as soft dots on a clear texture: faint where the sky is clear, a red glow where it's blocked.
    /// Same dotted look as the radar, so the two views read as one instrument.
    static func skyTexture(_ map: ObstructionMap) -> CGImage? {
        let cell = 8
        let w = map.cols * cell, h = map.rows * cell
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let clear = NSColor(Palette.accent).withAlphaComponent(0.32).cgColor
        let blocked = NSColor(Palette.bad).cgColor
        let blockedGlow = NSColor(Palette.bad).withAlphaComponent(0.25).cgColor
        for row in 0..<map.rows {
            for col in 0..<map.cols {
                let v = map.snr[row * map.cols + col]
                guard v >= 0 else { continue }
                let cx = CGFloat(col * cell) + CGFloat(cell) / 2
                let cy = CGFloat((map.rows - 1 - row) * cell) + CGFloat(cell) / 2
                if v < 0.5 {
                    ctx.setFillColor(blockedGlow)
                    ctx.fillEllipse(in: CGRect(x: cx - 4, y: cy - 4, width: 8, height: 8))
                    ctx.setFillColor(blocked)
                    ctx.fillEllipse(in: CGRect(x: cx - 2.4, y: cy - 2.4, width: 4.8, height: 4.8))
                } else {
                    ctx.setFillColor(clear)
                    ctx.fillEllipse(in: CGRect(x: cx - 1.8, y: cy - 1.8, width: 3.6, height: 3.6))
                }
            }
        }
        return ctx.makeImage()
    }

    /// A round gradient, white (or black) with alpha falling off by the given stops (0 is the centre, 0.5 the edge).
    static func radial(side: Int, stops: [(CGFloat, CGFloat)], white: CGFloat = 1) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: stops.map { CGColor(red: white, green: white, blue: white, alpha: $0.1) } as CFArray,
                                        locations: stops.map { $0.0 * 2 }) else { return nil }
        let c = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(side) / 2, options: [])
        return ctx.makeImage()
    }

    private static func scale(_ sat: VisibleSatellite, best: Int?, hovered: Int?) -> Float {
        if sat.id == best { return 1.6 }
        if sat.id == hovered { return 1.5 }
        return sat.elevation >= SkyWatch.serviceElevation ? 1 : 0.7
    }
}

struct DomeView: NSViewRepresentable {
    var map: ObstructionMap?
    var alignment: Alignment?
    var sky = SkyOverlay()
    var showMap = true
    /// Live throughput in bits per second, for the traffic on the satellite link.
    var down: Double? = nil
    var up: Double? = nil

    func makeCoordinator() -> DomeScene { DomeScene() }

    func makeNSView(context: Context) -> OrbitView {
        let view = SceneKitHelpers.makeView(scene: context.coordinator.scene, camera: context.coordinator.camera)
        let scene = context.coordinator
        view.onHover = { [weak view] point in
            guard let view else { return }
            scene.hover(at: point, in: view)
        }
        // Low and pulled back: the dome on the ground in front, the horizon behind, and the satellites
        // overhead in the upper part of the view.
        view.configure(target: [0, 1.0, 0], yaw: 0.35, pitch: 0.12, distance: 6.4,
                       pitchRange: 0.04...1.5, distanceRange: 1.6...11)
        return view
    }

    func updateNSView(_ view: OrbitView, context: Context) {
        context.coordinator.update(map: map, alignment: alignment)
        context.coordinator.update(sky: sky)
        context.coordinator.setMapVisible(showMap)
        context.coordinator.setTraffic(down: down, up: up)
    }
}

/// Small deterministic generator, so procedural scenery comes out the same every time.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    /// Uniform in 0..<1.
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    /// Standard normal, by Box-Muller.
    mutating func gaussian() -> Double {
        let u = max(next(), 1e-9), v = next()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}
