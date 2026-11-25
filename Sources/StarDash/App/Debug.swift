import AppKit
import SwiftUI
import SceneKit
import Metal

@MainActor
enum Probe {
    static func run() async {
        let settings = Settings.shared
        let dish = GRPCWebClient(host: settings.dishHost, port: 9201, avoidTunnels: settings.avoidTunnels)
        let router = GRPCWebClient(host: settings.routerHost, port: 9001, avoidTunnels: settings.avoidTunnels)

        do {
            let response = try await dish.call(1004)
            guard let body = response.message(2004) else { throw TelemetryError.malformed }
            let s = DishStatus(body)
            print("dish        \(s.modelName) (\(s.hardwareVersion ?? "?")) fw \(s.softwareVersion ?? "?")")
            print("state       \(s.state.title), uptime \(Fmt.duration(s.uptime.map(Double.init)))")
            print("latency     \(Fmt.ms(s.latencyMs)), drop \(Fmt.percent(s.dropRate))")
            print("throughput  down \(Fmt.rate(s.downBps, bytes: false)), up \(Fmt.rate(s.upBps, bytes: false))")
            print("obstructed  \(Fmt.percent(s.obstruction.fraction, digits: 2))")
            print("pointing    az \(Fmt.degrees(s.alignment.azimuth)) el \(Fmt.degrees(s.alignment.elevation)), ideal az \(Fmt.degrees(s.alignment.desiredAzimuth)) el \(Fmt.degrees(s.alignment.desiredElevation))")
            print("alerts      \(s.alerts.isEmpty ? "none" : s.alerts.joined(separator: ", "))")
        } catch {
            print("dish        FAILED: \(error.localizedDescription)")
        }

        if let response = try? await dish.call(1007, timeout: 6), let body = response.message(2006) {
            let h = DishHistory(body)
            let power = h.power.last.map { Fmt.watts(Double($0)) } ?? Fmt.missing
            print("history     \(h.latency.count) samples, \(h.events.count) events, power now \(power)")
            for e in h.events.prefix(3) {
                print("  event     \(Fmt.dayClock.string(from: e.start))  \(e.title)  \(Fmt.duration(e.duration))  [\(e.source)]")
            }
        } else {
            print("history     FAILED")
        }

        if let response = try? await dish.call(2008, timeout: 8), let body = response.message(2008),
           let map = ObstructionMap(body) {
            print("sky map     \(map.rows)x\(map.cols), \(Fmt.percent(map.coverage, digits: 0)) mapped, \(Fmt.percent(map.sampledFraction, digits: 2)) of sampled cells blocked")
        } else {
            print("sky map     FAILED")
        }

        if let response = try? await dish.call(2011) {
            let c = DishConfig(response.message(2011)?.message(1) ?? .empty)
            print("dish config snow melt \(c.snowMelt.label), sleep \(c.sleepEnabled ? "on" : "off") start \(c.sleepStartMinutes) min UTC for \(c.sleepDurationMinutes) min, update hour \(c.updateHour) UTC, defer \(c.deferUpdates), reply present \(response.has(2011))")
        } else {
            print("dish config FAILED")
        }

        do {
            let response = try await router.call(3009)
            print("wifi config read: \(response.has(3009) ? "allowed" : "empty reply")")
        } catch {
            print("wifi config read: refused (\(error.localizedDescription))")
        }

        do {
            let response = try await dish.call(1017)
            let lla = response.message(1017)?.message(1)
            print("location    \(lla == nil ? "no fix in reply" : "available") (reply \(response.message(1017) == nil ? "empty" : "present"))")
        } catch {
            print("location    FAILED: \(error.localizedDescription)")
        }

        do {
            let response = try await router.call(1004)
            guard let body = response.message(3004) else { throw TelemetryError.malformed }
            let r = RouterStatus(body)
            print("router      \(r.modelName) fw \(r.softwareVersion ?? "?"), \(r.clients.filter { !$0.isInfrastructure }.count) clients, ssids \(Set(r.ssids.map(\.ssid)).count)")
            print("roles       \(r.clients.map { "\($0.isInfrastructure ? $0.name : "client"):\($0.role)" }.joined(separator: ", "))")
            let probeStore = TelemetryStore()
            await probeStore.backfillPings(router)
            let values = probeStore.pings.map { Double($0.internet) }.sorted()
            print("router hist \(probeStore.pings.count) points over \(Fmt.duration(Double((probeStore.pings.last?.t ?? 0) - (probeStore.pings.first?.t ?? 0)))), median \(values.isEmpty ? 0 : values[values.count / 2]) ms")
            if let device = r.clients.first(where: { $0.isWireless && !$0.isInfrastructure }) {
                let h = await probeStore.clientHistory(device)
                let signals = h.map(\.signal).filter { $0 != 0 }
                print("client hist \(h.count) points, signal \(signals.min() ?? 0)...\(signals.max() ?? 0) dBm, peak down \(Fmt.rate(Double(h.map(\.down).max() ?? 0) * 8, bytes: false))")
            }
            print("router ping dish \(Fmt.ms(r.dishLatencyMs)), pop \(Fmt.ms(r.popLatencyMs)), internet \(Fmt.ms(r.pingLatencyMs))")
        } catch {
            print("router      FAILED: \(error.localizedDescription)")
        }
    }
}

@MainActor
enum SpeedProbe {
    /// Runs one real speed test and prints each stage. Uses real data.
    static func run() async {
        let store = TelemetryStore()
        store.windowOpen = true
        try? await Task.sleep(for: .seconds(3))
        let test = SpeedTest()
        if arguments.contains("mac-only") { test.includeRouter = false }
        let printer = Task { @MainActor in
            var last = SpeedTest.Stage.idle
            while !Task.isCancelled {
                if test.stage != last {
                    last = test.stage
                    print("stage       \(test.stage.title)")
                } else if test.stage == .macUp || test.stage == .macDown, test.liveSeries.count % 5 == 0, !test.liveSeries.isEmpty {
                    // Trace of the live gauge reading, to check it moves smoothly.
                    print(String(format: "  live      %.1f", test.liveMbps))
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        await test.run(store: store)
        printer.cancel()
        let r = test.current
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "--" }
        print("router      down \(f(r.routerDown)) up \(f(r.routerUp)) Mbps")
        print("this mac    down \(f(r.macDown)) up \(f(r.macUp)) Mbps, latency \(f(r.latency)) ms, jitter \(f(r.jitter)) ms")
        print("dish peak   down \(Fmt.rate(r.dishPeakDown, bytes: false)) up \(Fmt.rate(r.dishPeakUp, bytes: false))")
        print("error       \(test.error ?? "none"), history \(test.history.count)")
    }
}

@MainActor
enum Snapshot {
    static func run(directory: String) async {
        let store = TelemetryStore()
        let speedTest = SpeedTest()
        store.popoverOpen = true
        // Let a few polls land so status, history, map and router are all populated.
        try? await Task.sleep(for: .seconds(4))

        let dark = arguments.contains("--light") ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func shoot(_ name: String, size requested: CGSize? = nil, _ view: some View) async {
            let size = requested ?? PopoverRoot.size
            let root = view
                .environment(store)
                .environment(speedTest)
                .environment(AppActions())
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = dark
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(700))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
            }
            window.orderOut(nil)
        }

        if arguments.contains("--account") {
            // The Starlink-account pages, rendered full height. Only reads from the account; never writes.
            let account = Account.shared
            await account.loadProfile()
            await account.loadBilling()
            await account.loadRouter()
            print("account \(account.signedIn ? "signed in" : "signed out"), billing \(account.billing != nil), router \(account.router != nil), error \(account.routerError ?? "none")")
            let overlays = Overlays.shared
            let clients = store.router?.clients ?? []
            await shoot("acct-settings", size: CGSize(width: 620, height: 560),
                        StarlinkAccountPanel().environment(overlays).padding(20).background(.black))
            await shoot("acct-billing", size: CGSize(width: 1080, height: 760),
                        BillingUsageView().padding(20).background(.black))
            await shoot("acct-network", size: CGSize(width: 1080, height: 2400), MainWindow(pane: .network))
            await shoot("acct-device", size: CGSize(width: 1080, height: 2000), MainWindow(pane: .device))
            await shoot("acct-rule-editor", size: CGSize(width: 640, height: 1000),
                        RuleEditor(rule: nil, clients: clients).environment(overlays).padding(20).background(.black))
            if let networks = account.router?.networks {
                await shoot("acct-wifi-editor", size: CGSize(width: 620, height: 600),
                            WifiEditor(networks: networks) { _ in }.environment(overlays).padding(20).background(.black))
            }
            await shoot("acct-dns-editor", size: CGSize(width: 620, height: 520),
                        DNSEditor(current: account.router?.nameservers ?? []) { _, _ in }.environment(overlays).padding(20).background(.black))
            print("account done")
            return
        }

        if arguments.contains("--pop") {
            let saved = Settings.shared.themeName
            for theme in ["mono", "glass"] {
                Settings.shared.themeName = theme
                await shoot("pop-\(theme)", PopoverRoot())
            }
            Settings.shared.themeName = saved
            print("pop done")
            return
        }

        if arguments.contains("--next") {
            // The globe with the real constellation, and the Device page with its controls.
            await SatelliteCatalog.shared.refreshIfNeeded()
            let shell = await SatelliteCatalog.shared.shell(at: Date())
            let globe = GlobeScene()
            let target = simd_float3(0, 0.06, 0)
            globe.camera.simdPosition = target + simd_float3(0, sin(0.06), cos(0.06)) * 3.5
            globe.camera.simdLook(at: target, up: [0, 1, 0], localFront: [0, 0, -1])
            globe.update(country: store.dish?.countryCode, azimuth: store.dish?.alignment.azimuth,
                         elevation: store.dish?.alignment.elevation, color: Palette.nsState(store.state), online: store.state.isUp)
            globe.update(shell: shell)
            let size = CGSize(width: 1200, height: 860)
            let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            renderer.scene = globe.scene
            renderer.pointOfView = globe.camera
            let image = renderer.snapshot(atTime: 3, with: size, antialiasingMode: .multisampling4X)
            let canvas = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setFill()
                rect.fill()
                image.draw(in: rect)
                return true
            }
            if let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("globe-real.png"))
            }
            await store.loadDishConfig()
            let saved = Settings.shared.themeName
            Settings.shared.themeName = "mono"
            await shoot("device-controls", size: CGSize(width: 1080, height: 1100), MainWindow(pane: .device))
            Settings.shared.themeName = saved
            print("next done, \(shell.count) satellites on the globe")
            return
        }

        if arguments.contains("--dome") {
            // The 3D dome with satellites, drawn straight from the scene. Uses a stand-in location if none is set.
            let s = Settings.shared
            let had = s.hasSite
            if !had { s.setSite(latitude: 47.6, longitude: -122.3) }
            SkyWatch.shared.start(site: { store.site }, floor: { 10 })
            for _ in 0..<40 where SkyWatch.shared.satellites.isEmpty { try? await Task.sleep(for: .seconds(1)) }
            let watch = SkyWatch.shared
            let best = watch.bestPlaced(alignment: store.dish?.alignment, map: store.map)
            let dome = DomeScene()
            let yaw: Float = 0.35, pitch: Float = 0.5, distance: Float = 3.3
            let target = simd_float3(0, 0.32, 0)
            dome.camera.simdPosition = target + simd_float3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
            dome.camera.simdLook(at: target, up: [0, 1, 0], localFront: [0, 0, -1])
            dome.update(map: store.map, alignment: store.dish?.alignment)
            dome.update(sky: SkyOverlay(satellites: watch.satellites, ahead: watch.ahead, best: best?.id))
            // A busy link, eased in the way a second of polling would.
            for _ in 0..<6 { dome.setTraffic(down: 150e6, up: 15e6) }
            let size = CGSize(width: 1200, height: 860)
            let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            renderer.scene = dome.scene
            renderer.pointOfView = dome.camera
            let image = renderer.snapshot(atTime: 3, with: size, antialiasingMode: .multisampling4X)
            let canvas = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setFill()
                rect.fill()
                image.draw(in: rect)
                return true
            }
            if let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("dome-satellites.png"))
            }
            await shoot("dash-satellites", size: CGSize(width: 1080, height: 760), MainWindow(pane: .overview))
            watch.stop()
            if !had { s.hasSite = false }
            print("dome done, \(watch.satellites.count) satellites")
            return
        }

        if arguments.contains("--dishy") {
            // Checks the newer pages. Uses a stand-in location for the satellite chart and puts the real setting back.
            let s = Settings.shared
            let saved = (s.themeName, s.hasSite, s.siteLatitude, s.siteLongitude, UserDefaults.standard.string(forKey: "skyStyle"))
            let size = CGSize(width: 1080, height: 760)
            if !s.hasSite { s.setSite(latitude: 47.6, longitude: -122.3) }
            SkyWatch.shared.start(site: { store.site }, floor: { 10 })
            for _ in 0..<40 where SkyWatch.shared.satellites.isEmpty { try? await Task.sleep(for: .seconds(1)) }
            print("satellites  \(SkyWatch.shared.satellites.count) in view of \(SkyWatch.shared.catalogCount), error \(SkyWatch.shared.error ?? "none")")
            // Stand-in time-lapse: the current map revealed in steps.
            if store.mapFrames.count < 2, let map = store.map {
                store.mapFrames = (1...6).map { step in
                    var copy = map
                    for i in copy.snr.indices where i % map.cols > map.cols * step / 6 { copy.snr[i] = -1 }
                    return MapFrame(copy, at: Date().addingTimeInterval(Double(step - 6) * 600))
                }
            }
            try? await Task.sleep(for: .seconds(8))
            print("tracking    \(store.pings.count) pings, \(store.alertLog.count) alerts, \(store.deviceSeries.count) devices, \(store.mapFrames.count) frames")
            for theme in ["mono", "glass"] {
                s.themeName = theme
                UserDefaults.standard.set("dome", forKey: "skyStyle")
                await shoot("dishy-\(theme)-dome", size: size, MainWindow(pane: .sky))
                UserDefaults.standard.set("radar", forKey: "skyStyle")
                await shoot("dishy-\(theme)-radar", size: size, MainWindow(pane: .sky))
                UserDefaults.standard.set("horizon", forKey: "skyStyle")
                await shoot("dishy-\(theme)-horizon", size: size, MainWindow(pane: .sky))
                SkyPane.stagedFrame = 2
                UserDefaults.standard.set("radar", forKey: "skyStyle")
                await shoot("dishy-\(theme)-lapse", size: size, MainWindow(pane: .sky))
                SkyPane.stagedFrame = nil
                await shoot("dishy-\(theme)-device", size: CGSize(width: 1080, height: 1400), MainWindow(pane: .device))
                await shoot("dishy-\(theme)-network", size: CGSize(width: 1080, height: 1400), MainWindow(pane: .network))
                if let client = store.router?.clients.first(where: { $0.isWireless && !$0.isInfrastructure }) {
                    Overlays.shared.sheet = SheetRequest(id: client.id, content: AnyView(DeviceDetail(id: client.id, name: client.name)))
                    await shoot("dishy-\(theme)-detail", size: size, MainWindow(pane: .network))
                    Overlays.shared.sheet = nil
                }
                await shoot("dishy-\(theme)-pop-sky", PopoverRoot())
            }
            SkyWatch.shared.stop()
            s.themeName = saved.0
            s.siteLatitude = saved.2
            s.siteLongitude = saved.3
            s.hasSite = saved.1
            UserDefaults.standard.set(saved.4, forKey: "skyStyle")
            print("dishy shots done")
            return
        }

        if arguments.contains("--overlays") {
            let saved = Settings.shared.themeName
            let size = CGSize(width: 1080, height: 760)
            for theme in ["mono", "glass"] {
                Settings.shared.themeName = theme
                await shoot("over-\(theme)-settings", size: size, MainWindow(pane: .settings))
                Overlays.shared.menu = MenuRequest(anchor: CGRect(x: 900, y: 560, width: 130, height: 28), options: [
                    ("Every second", true, {}), ("Every 2 seconds", false, {}), ("Every 5 seconds", false, {}), ("Every 15 seconds", false, {}),
                ])
                await shoot("over-\(theme)-menu", size: size, MainWindow(pane: .settings))
                Overlays.shared.menu = nil
                Overlays.shared.confirm = ConfirmRequest(title: "Reboot the dish?",
                    message: "Everything on this network goes offline for a few minutes.", action: "Reboot") {}
                await shoot("over-\(theme)-confirm", size: size, MainWindow(pane: .device))
                Overlays.shared.confirm = nil
                await shoot("over-\(theme)-dashboard", size: size, MainWindow(pane: .overview))
                await shoot("over-\(theme)-pop-overview", PopoverRoot())
                await shoot("over-\(theme)-pop-events", PopoverRoot())
                await shoot("over-\(theme)-pop-settings", PopoverRoot())
                Overlays.popover.confirm = ConfirmRequest(title: "Reboot the dish?",
                    message: "Everything on this network goes offline for a few minutes.", action: "Reboot") {}
                await shoot("over-\(theme)-pop-confirm", PopoverRoot())
                Overlays.popover.confirm = nil
            }
            Settings.shared.themeName = saved
            print("overlay shots done")
            return
        }

        if arguments.contains("--route") {
            let saved = (speedTest.includeRouter, speedTest.includeMac, Settings.shared.themeName)
            let size = CGSize(width: 1080, height: 760)
            speedTest.history.insert(SpeedResult(date: Date(), macDown: 142, macUp: 12.4, routerDown: 171, routerUp: 19.2, latency: 23, jitter: 1.8,
                                                   server: Ookla.demo[0].label), at: 0)
            for theme in ["mono", "glass"] {
                Settings.shared.themeName = theme
                speedTest.includeRouter = false
                await shoot("route-\(theme)-idle", size: size, MainWindow(pane: .speed))
                speedTest.includeRouter = true
                SpeedPane.stagedResult = true
                await shoot("route-\(theme)-done", size: size, MainWindow(pane: .speed))
                await shoot("route-\(theme)-small", size: CGSize(width: 940, height: 640), MainWindow(pane: .speed))
                SpeedPane.stagedResult = false
            }
            speedTest.includeRouter = saved.0
            speedTest.includeMac = saved.1
            Settings.shared.themeName = saved.2
            print("route shots done")
            return
        }

        await shoot("popover", PopoverRoot())
        await shoot("popover-latency", PopoverRoot(detail: .latency))
        await shoot("popover-data", PopoverRoot(detail: .data))
        await shoot("popover-power", PopoverRoot(detail: .power))
        if arguments.contains("--update") {
            // The update notice in the popover and Settings, with a made-up offer.
            AppUpdater.shared.showDemoOffer()
            await shoot("popover-update", PopoverRoot())
            await shoot("window-settings-update", size: CGSize(width: 1080, height: 1300), MainWindow(pane: .settings))
            AppUpdater.shared.later()
        }
        await shoot("settings", PopoverRoot())
        for pane in [Pane.overview, .speed, .sky, .network, .device, .events, .settings] {
            await shoot("window-\(pane.rawValue)", size: CGSize(width: 1080, height: 760), MainWindow(pane: pane))
        }

        let previousSky = UserDefaults.standard.string(forKey: "skyStyle")
        // A staged mid-run frame and sample history, for checking the Speed page layout. Never saved.
        if speedTest.history.isEmpty {
            var fake: [SpeedResult] = []
            for i in 0..<9 {
                let down: Double = 80 + Double((i * 37) % 90)
                let up: Double = 9 + Double(i % 5) * 2
                let ping: Double = 24 + Double(i % 4) * 3
                fake.append(SpeedResult(date: Date().addingTimeInterval(Double(i) * -5400), macDown: down, macUp: up,
                                        routerDown: down + 60, routerUp: 18, latency: ping, jitter: 2.5))
            }
            speedTest.history = fake
        }
        await shoot("window-speed-done", size: CGSize(width: 1080, height: 760), MainWindow(pane: .speed))
        speedTest.stage = .macDown
        speedTest.liveMbps = 142
        speedTest.progress = 0.62
        var series: [Double] = []
        for i in 0..<28 {
            let ramp: Double = 1 - exp(Double(i) / -5)
            series.append(60 + 80 * ramp + Double((i * 7) % 9))
        }
        speedTest.liveSeries = series
        speedTest.current = SpeedResult(date: Date(), routerDown: 171, routerUp: 19.2, latency: 23, jitter: 1.8, dishPeakDown: 168_000_000)
        await shoot("window-speed-running", size: CGSize(width: 1080, height: 760), MainWindow(pane: .speed))
        for style in ["radar", "horizon"] {
            UserDefaults.standard.set(style, forKey: "skyStyle")
            await shoot("window-sky-\(style)", size: CGSize(width: 1080, height: 760), MainWindow(pane: .sky))
        }
        UserDefaults.standard.set(previousSky, forKey: "skyStyle")
        Settings.shared.themeName = "mono"
        for pane in Pane.allCases {
            await shoot("mono-\(pane.rawValue)", size: CGSize(width: 1080, height: 760), MainWindow(pane: pane))
        }
        await shoot("mono-popover", PopoverRoot())
        await shoot("mono-overview-small", size: CGSize(width: 940, height: 640), MainWindow(pane: .overview))
        Settings.shared.themeName = "glass"
        await shoot("window-overview-small", size: CGSize(width: 940, height: 640), MainWindow(pane: .overview))
        await shoot("window-speed-small", size: CGSize(width: 940, height: 640), MainWindow(pane: .speed))
        speedTest.stage = .idle

        // SceneKit views don't show up in cacheDisplay, so render the scenes on their own.
        func render(_ name: String, _ scene: SCNScene, _ camera: SCNNode, _ size: CGSize) {
            let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            renderer.scene = scene
            renderer.pointOfView = camera
            let image = renderer.snapshot(atTime: 3, with: size, antialiasingMode: .multisampling4X)
            let canvas = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setFill()
                rect.fill()
                image.draw(in: rect)
                return true
            }
            if let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
        func place(_ camera: SCNNode, target: simd_float3, yaw: Float, pitch: Float, distance: Float) {
            camera.simdPosition = target + simd_float3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
            camera.simdLook(at: target, up: [0, 1, 0], localFront: [0, 0, -1])
        }
        let globe = GlobeScene()
        place(globe.camera, target: [0, 0.06, 0], yaw: 0, pitch: 0.06, distance: 3.5)
        globe.update(country: store.dish?.countryCode, azimuth: store.dish?.alignment.azimuth,
                     elevation: store.dish?.alignment.elevation, color: Palette.nsState(store.state), online: store.state.isUp)
        render("scene-globe", globe.scene, globe.camera, CGSize(width: 1200, height: 860))
        let dome = DomeScene()
        place(dome.camera, target: [0, 0.32, 0], yaw: 0.35, pitch: 0.5, distance: 3.3)
        dome.update(map: store.map, alignment: store.dish?.alignment)
        render("scene-dome", dome.scene, dome.camera, CGSize(width: 1200, height: 860))

        // Menu bar readout with every item on, drawn the way the status item would.
        let saved = Settings.shared.menuBarItems
        Settings.shared.menuBarItems = MenuBarItem.allCases
        let bar = MenuBarRenderer.image(store: store, settings: Settings.shared, leadingInset: 10)
        Settings.shared.menuBarItems = saved
        let tinted = NSImage(size: bar.size, flipped: false) { rect in
            bar.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let canvas = NSImage(size: NSSize(width: bar.size.width + 16, height: 24), flipped: false) { rect in
            NSColor(white: 0.12, alpha: 1).setFill()
            rect.fill()
            tinted.draw(in: NSRect(x: 8, y: 1, width: bar.size.width, height: bar.size.height))
            return true
        }
        if let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("menubar.png"))
        }
        print("snapshots written to \(dir.path)")
    }
}

@MainActor
enum IconMaker {
    /// Renders docs/icon.svg onto the macOS icon grid (an 824 pt tile centred on a 1024 canvas).
    /// Run by scripts/bundle.sh, which turns the PNG into an .icns.
    static func write(to path: String, from svg: String) {
        guard let art = NSImage(contentsOf: URL(fileURLWithPath: svg)) else {
            FileHandle.standardError.write(Data("can't read \(svg)\n".utf8))
            exit(1)
        }
        let side: CGFloat = 1024
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            art.draw(in: NSRect(x: 100, y: 100, width: 824, height: 824))
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

/// Drives the real window with scripted pointer events and saves pictures of it, so the live app
/// can be checked without anyone at the mouse. Steps come from `--steps`, separated by semicolons:
/// `pane:sky`, `wait:1.5`, `move:x,y`, `click:x,y`, `drag:x1,y1,x2,y2`, `scroll:x,y,dy`, `key:esc`, `snap:name`,
/// `servers` (opens the speed test server picker), `server:N` (picks the Nth Ookla demo server, 0 for Cloudflare).
/// Coordinates are points from the top-left of the window's content.
@MainActor
enum Driver {
    static var directory: String? {
        guard let i = arguments.firstIndex(of: "--drive"), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    static func run(window: NSWindow, showPane: @escaping (Pane) -> Void) async {
        guard let directory, let i = arguments.firstIndex(of: "--steps"), i + 1 < arguments.count else { return }
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        window.setContentSize(NSSize(width: 1080, height: 760))
        try? await Task.sleep(for: .seconds(3))
        var eventNumber = 1

        func location(_ x: Double, _ y: Double) -> NSPoint {
            NSPoint(x: x, y: Double(window.contentView?.bounds.height ?? 760) - y)
        }
        func post(_ type: NSEvent.EventType, _ x: Double, _ y: Double, clicks: Int = 1) {
            eventNumber += 1
            guard let event = NSEvent.mouseEvent(with: type, location: location(x, y), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: eventNumber, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1) else { return }
            NSApp.postEvent(event, atStart: false)
        }
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        // Hover follows the real pointer, so hover checks put it on the spot for a moment.
        func hover(_ x: Double, _ y: Double) async {
            let onScreen = window.convertPoint(toScreen: location(x, y))
            let height = NSScreen.screens.first?.frame.height ?? 0
            for k in 0...3 {
                CGWarpMouseCursorPosition(CGPoint(x: onScreen.x - Double(3 - k) * 4, y: height - onScreen.y - Double(3 - k) * 3))
                post(.mouseMoved, x - Double(3 - k) * 4, y - Double(3 - k) * 3)
                await pause(0.08)
            }
            await pause(0.25)
        }

        for step in arguments[i + 1].split(separator: ";") {
            // Hover only registers in the frontmost window, and someone may have clicked elsewhere meanwhile.
            if !window.isKeyWindow || !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                await pause(0.3)
            }
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let values = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
            switch parts[0] {
            case "pane":
                if let pane = Pane(rawValue: parts[1]) { showPane(pane) }
                await pause(1.2)
            case "wait":
                await pause(values.first ?? 1)
            case "move" where values.count == 2:
                // A few steps toward the spot, the way a hand arrives.
                await hover(values[0], values[1])
            case "click" where values.count == 2:
                if let content = window.contentView, let hit = content.hitTest(content.superview?.convert(location(values[0], values[1]), from: nil) ?? .zero) {
                    print("click \(Int(values[0])),\(Int(values[1])) lands on \(type(of: hit)) frame \(hit.convert(hit.bounds, to: nil).integral)")
                }
                post(.mouseMoved, values[0], values[1])
                await pause(0.1)
                post(.leftMouseDown, values[0], values[1])
                await pause(0.08)
                post(.leftMouseUp, values[0], values[1])
                await pause(0.7)
            case "drag" where values.count == 4:
                post(.leftMouseDown, values[0], values[1])
                for k in 1...10 {
                    let f = Double(k) / 10
                    post(.leftMouseDragged, values[0] + (values[2] - values[0]) * f, values[1] + (values[3] - values[1]) * f)
                    await pause(0.03)
                }
                post(.leftMouseUp, values[2], values[3])
                await pause(0.6)
            case "scroll" where values.count == 3:
                await hover(values[0], values[1])
                if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-values[2]), wheel2: 0, wheel3: 0),
                   let event = NSEvent(cgEvent: cg) {
                    NSApp.postEvent(event, atStart: false)
                }
                await pause(0.8)
            case "size" where values.count == 2:
                window.setContentSize(NSSize(width: values[0], height: values[1]))
                await pause(0.8)
            case "key" where parts.count > 1:
                let code: UInt16 = parts[1] == "esc" ? 53 : 36
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: parts[1] == "esc" ? "\u{1b}" : "\r",
                                                    charactersIgnoringModifiers: parts[1] == "esc" ? "\u{1b}" : "\r", isARepeat: false, keyCode: code) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                await pause(0.6)
            case "radarsat" where values.count == 3, "horizonsat" where values.count == 5:
                // Points at a real satellite, working out where the chart has drawn it.
                let pick = SkyWatch.shared.satellites.filter { $0.elevation >= 35 && $0.elevation <= 75 }.last
                guard let sat = pick else { print("no satellite to point at"); break }
                var x = 0.0, y = 0.0
                if parts[0] == "radarsat" {
                    let f = (90 - sat.elevation) / 80, a = sat.azimuth * .pi / 180
                    x = values[0] + sin(a) * values[2] * f
                    y = values[1] - cos(a) * values[2] * f
                } else {
                    x = values[0] + values[2] * sat.azimuth / 360
                    y = values[1] + values[3] * (90 - sat.elevation) / (90 - values[4])
                }
                print("pointing at \(sat.name) at \(Int(x)),\(Int(y))")
                await hover(x, y)
                snap(window, to: dir.appendingPathComponent("sat-\(eventNumber).png"))
                print("crop sat-\(eventNumber) \(Int(x)) \(Int(y))")
            case "domesat":
                var scenes: [SCNView] = []
                func collect(_ v: NSView) {
                    if let scene = v as? SCNView { scenes.append(scene) }
                    v.subviews.forEach(collect)
                }
                if let content = window.contentView { collect(content) }
                guard let scene = scenes.first, let root = scene.scene?.rootNode else { print("no 3D view"); break }
                // The beads are the small spheres; take one near the middle of the view.
                var target: NSPoint?
                root.enumerateHierarchy { node, _ in
                    guard let sphere = node.geometry as? SCNSphere, sphere.radius < 0.02, !node.isHidden, node.scale.x < 1.5, node.scale.x > 0.9 else { return }
                    let p = scene.projectPoint(node.worldPosition)
                    let inWindow = scene.convert(NSPoint(x: CGFloat(p.x), y: CGFloat(p.y)), to: nil)
                    if target == nil, abs(inWindow.x - 375) < 150 { target = inWindow }
                }
                guard let target else { print("no bead found"); break }
                let top = Double(window.contentView?.bounds.height ?? 760) - Double(target.y)
                print("pointing at a bead at \(Int(target.x)),\(Int(top))")
                await hover(Double(target.x), top)
            case "servers":
                SpeedServerPicker.open()
                await pause(1.5)
            case "server" where values.count == 1:
                let n = Int(values[0])
                Settings.shared.speedServer = n == 0 ? .cloudflare : n < 0 ? .auto : .ookla(Ookla.demo[min(n, Ookla.demo.count) - 1])
                await pause(0.5)
            case "snap" where parts.count > 1:
                snap(window, to: dir.appendingPathComponent("\(parts[1]).png"))
            default:
                print("skipped step \(step)")
            }
        }
        print("drive done")
        exit(0)
    }

    private static func snap(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        // 3D views don't draw into that picture, so their own snapshots are laid on top.
        var scenes: [SCNView] = []
        func collect(_ v: NSView) {
            if let scene = v as? SCNView { scenes.append(scene) }
            v.subviews.forEach(collect)
        }
        collect(view)
        let composed = NSImage(size: view.bounds.size, flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            image.draw(in: rect)
            for scene in scenes {
                var frame = scene.convert(scene.bounds, to: view)
                if view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY }
                scene.snapshot().draw(in: frame)
                // Lay the controls drawn over the 3D view back on top. Lighten keeps light text and lines and
                // lets the scene show through the dark gaps between them.
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: frame).addClip()
                image.draw(in: rect, from: .zero, operation: .lighten, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        if let tiff = composed.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}

/// `--demo` swaps out everything that identifies the owner (country, Wi-Fi name, device names,
/// addresses, location) for stand-ins, so the app can be screenshotted for the README.
/// Nothing is saved while it's on, so the stand-ins never reach the real history.
enum Demo {
    static let on = CommandLine.arguments.contains("--demo")
    static let site = GeoPoint(latitude: 47.6, longitude: -122.3)
    private static let names = ["MacBook Pro", "iPhone", "iPad", "Living room TV", "Pixel 9", "Work laptop", "HomePod"]

    static func scrub(_ dish: inout DishStatus) {
        dish.countryCode = "US"
    }

    static func scrub(_ router: inout RouterStatus) {
        router.ssids = router.ssids.map { (ssid: "Starlink", band: $0.band) }
        var n = 0
        router.clients = router.clients.map { c in
            var c = c
            guard !c.isInfrastructure else { return c }
            c.name = names[n % names.count]
            c.ip = "192.168.1.\(20 + n)"
            n += 1
            return c
        }
    }
}
