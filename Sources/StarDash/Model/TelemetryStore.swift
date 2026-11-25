import Foundation
import Observation

struct Sample {
    var t: Int32
    var latency: Float
    var drop: Float
    var down: Float
    var up: Float
    var power: Float

    var date: Date { Date(timeIntervalSince1970: Double(t)) }
}

struct WindowStats {
    var medianLatency: Double?
    var jitter: Double?
    var pingSuccess: Double?
    var avgPower: Double?
    var peakDown: Double?
    var peakUp: Double?
    var count = 0
}

struct Quality {
    var score: Int
    var label: String
    var detail: String
}

@MainActor
@Observable
final class TelemetryStore {
    // Dish
    var dish: DishStatus?
    var dishError: String?
    var lastDishUpdate: Date?
    var samples: [Sample] = []
    var events: [LinkEvent] = []
    /// Each wireless device's band at the last poll, to spot a switch.
    @ObservationIgnored var clientBands: [String: (band: Int, seen: Date)] = [:]
    var map: ObstructionMap?

    // Router
    var router: RouterStatus?
    var routerError: String?
    var radios: [RadioStat] = []
    var interfaces: [NetInterface] = []
    var localIPs: Set<String> = []

    var popoverOpen = false {
        didSet { if popoverOpen { wake() } }
    }

    var windowOpen = false {
        didSet { if windowOpen { wake() } }
    }

    /// Someone is looking, so poll at full rate and fetch the heavier endpoints.
    private var visible: Bool { popoverOpen || windowOpen }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var lastCurrent = 0
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private let settings = Settings.shared

    static let maxSamples = 86_400

    /// Hourly traffic and energy, kept for five weeks. See Usage.swift.
    var hours: [HourBucket] = []
    var deviceUsage: [String: DeviceUsage] = [:]
    @ObservationIgnored var usageMonth = TelemetryStore.monthKey()

    /// Kept by StarDash itself. See Tracking.swift.
    var mapFrames: [MapFrame] = []
    var pings: [PingSample] = []
    var alertLog: [AlertRecord] = []
    var deviceSeries: [String: [DevicePoint]] = [:]
    /// Set only when the dish is allowed to share its position.
    var dishLocation: GeoPoint?
    /// The dish's settings, loaded when the Device page opens.
    var dishConfig: DishConfig?
    @ObservationIgnored var deviceCounters: [String: (t: Double, down: Double, up: Double)] = [:]
    @ObservationIgnored var lastRouterHistory = Date.distantPast

    var dishClient: GRPCWebClient {
        GRPCWebClient(host: settings.dishHost, port: 9201, avoidTunnels: settings.avoidTunnels)
    }

    var routerClient: GRPCWebClient {
        GRPCWebClient(host: settings.routerHost, port: 9001, avoidTunnels: settings.avoidTunnels)
    }

    // MARK: Derived

    var state: LinkState {
        guard let dish, dishError == nil else { return .unreachable }
        return dish.state
    }

    var powerW: Double? {
        guard let p = samples.last?.power, p > 0, isFresh else { return nil }
        return Double(p)
    }

    var isFresh: Bool {
        guard let last = samples.last else { return false }
        return Date().timeIntervalSince(last.date) < 60
    }

    func window(_ seconds: Int) -> ArraySlice<Sample> {
        let cutoff = Int32(Date().timeIntervalSince1970) - Int32(seconds)
        var lo = 0
        var hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].t < cutoff { lo = mid + 1 } else { hi = mid }
        }
        return samples[lo...]
    }

    func stats(_ seconds: Int) -> WindowStats {
        let w = window(seconds)
        guard !w.isEmpty else { return WindowStats() }
        var s = WindowStats(count: w.count)
        let lat = w.filter { $0.drop < 1 && $0.latency > 0 }.map { Double($0.latency) }.sorted()
        if !lat.isEmpty {
            s.medianLatency = lat[lat.count / 2]
            let mean = lat.reduce(0, +) / Double(lat.count)
            s.jitter = (lat.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lat.count)).squareRoot()
        }
        s.pingSuccess = 1 - Double(w.reduce(Float(0)) { $0 + min(1, max(0, $1.drop)) }) / Double(w.count)
        let power = w.filter { $0.power > 0 }
        if !power.isEmpty { s.avgPower = Double(power.reduce(Float(0)) { $0 + $1.power }) / Double(power.count) }
        s.peakDown = w.map { Double($0.down) }.max()
        s.peakUp = w.map { Double($0.up) }.max()
        return s
    }

    /// 0-100 score for the last two minutes, weighted toward what breaks calls: loss, then jitter, then latency.
    var quality: Quality? {
        guard state.isUp else { return nil }
        let s = stats(120)
        guard s.count >= 10, let latency = s.medianLatency, let success = s.pingSuccess else { return nil }
        let loss = 1 - success
        let lossPenalty = min(50, loss / 0.05 * 50)
        let latencyPenalty = min(30, max(0, (latency - 40) / 110 * 30))
        let jitterPenalty = min(20, max(0, ((s.jitter ?? 0) - 5) / 35 * 20))
        let score = Int((100 - lossPenalty - latencyPenalty - jitterPenalty).rounded())
        switch score {
        case 85...: return Quality(score: score, label: "Excellent", detail: "Fine for video calls and gaming")
        case 65..<85: return Quality(score: score, label: "Good", detail: "Calls work, fast games may hiccup")
        case 40..<65: return Quality(score: score, label: "Fair", detail: "Expect choppy calls")
        default: return Quality(score: score, label: "Poor", detail: "Real-time apps will struggle")
        }
    }

    func outages(since seconds: TimeInterval) -> [LinkEvent] {
        let cutoff = Date().addingTimeInterval(-seconds)
        return events.filter { $0.isOutage && $0.start >= cutoff }
    }

    // MARK: Polling

    func start() {
        load()
        localIPs = LocalNetwork.ipv4Addresses()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let interval = self.visible ? 1.0 : self.settings.pollInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Restart the loop so an open popover gets fresh data right away.
    private func wake() {
        tick = 0
        loop?.cancel()
        start()
    }

    func stop() {
        loop?.cancel()
        save()
    }

    private func poll() async {
        let n = tick
        tick += 1
        let interval = visible ? 1.0 : settings.pollInterval
        func every(_ seconds: Double) -> Bool { n % max(1, Int(seconds / interval)) == 0 }

        await refreshStatus()
        if dishError == nil, every(5) { await refreshHistory() }
        if dishError == nil, every(visible ? 30 : 600) { await refreshMap() }
        if every(visible ? 5 : 60) { await refreshRouter() }
        if dishError == nil, visible, every(300) { await refreshLocation() }
        if Date().timeIntervalSince(lastSave) > 300 { save() }
    }

    private func refreshStatus() async {
        do {
            let response = try await dishClient.call(1004)
            guard let body = response.message(2004) else { throw TelemetryError.malformed }
            var status = DishStatus(body)
            if Demo.on { Demo.scrub(&status) }
            dish = status
            dishError = nil
            failures = 0
            lastDishUpdate = Date()
        } catch is CancellationError {
            return
        } catch {
            failures += 1
            // One dropped poll isn't an outage. Wait for a second miss before flipping the UI.
            if failures >= 2 || dish == nil {
                dishError = error.localizedDescription
            }
        }
        notifier.observe(state: state, dish: dish, settings: settings)
        notifier.watchQuality(store: self, settings: settings)
        recordAlerts()
    }

    private func refreshHistory() async {
        guard let response = try? await dishClient.call(1007, timeout: 6),
              let body = response.message(2006) else { return }
        let h = DishHistory(body)
        merge(h)
        if !h.events.isEmpty {
            var byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for e in h.events { byID[e.id] = e }
            events = Array(byID.values.sorted { $0.start > $1.start }.prefix(1000))
        }
    }

    private func merge(_ h: DishHistory) {
        let n = min(h.latency.count, h.drop.count, h.down.count, h.up.count)
        guard n > 0 else { return }
        let now = Int32(Date().timeIntervalSince1970)

        func sample(_ i: Int, _ t: Int32) -> Sample {
            Sample(t: t, latency: h.latency[i], drop: h.drop[i], down: h.down[i], up: h.up[i],
                   power: i < h.power.count ? h.power[i] : 0)
        }

        let advanced = h.current - lastCurrent
        if let last = samples.last, advanced > 0, advanced <= n, abs(Int(now) - Int(last.t) - advanced) <= 10 {
            // Same boot, contiguous counter: append exactly the new samples.
            for k in 0..<advanced {
                record(sample(n - advanced + k, last.t + Int32(k) + 1))
            }
        } else if advanced != 0 || samples.isEmpty {
            // First fetch, reboot, or a gap: place by wall clock and skip what we already hold.
            let lastT = samples.last?.t ?? 0
            for i in 0..<n {
                let t = now - Int32(n - 1 - i)
                if t > lastT { record(sample(i, t)) }
            }
        }
        lastCurrent = h.current
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
    }

    func refreshMap() async {
        guard let response = try? await dishClient.call(2008, timeout: 8),
              let body = response.message(2008) else { return }
        map = ObstructionMap(body)
        if let map { recordFrame(map) }
    }

    func refreshRouter() async {
        let client = routerClient
        do {
            let response = try await client.call(1004)
            guard let body = response.message(3004) else { throw TelemetryError.malformed }
            var status = RouterStatus(body)
            if Demo.on { Demo.scrub(&status) }
            router = status
            routerError = nil
            track(status.clients)
            noticeRouterChanges(status)
            recordPing(status)
            if Date().timeIntervalSince(lastRouterHistory) > 1800 {
                lastRouterHistory = Date()
                await backfillPings(client)
            }
            recordDevices(status.clients)
            RulesEngine.shared.routerUpdated()
        } catch is CancellationError {
            return
        } catch {
            routerError = error.localizedDescription
            router = nil
            return
        }
        localIPs = LocalNetwork.ipv4Addresses()
        guard visible else { return }
        if let r = try? await client.call(1036), let body = r.message(1035) {
            radios = body.messages(1).map(RadioStat.init)
        }
        if let r = try? await client.call(1015), let body = r.message(1015) {
            interfaces = body.messages(1).map(NetInterface.init)
        }
    }

    func rebootDish() async -> Bool {
        (try? await dishClient.call(1001)) != nil
    }

    // MARK: Persistence

    private var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StarDash", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private struct StoredEvent: Codable {
        var reason: Int, severity: Int, start: Double, duration: Double, source: String
        var detail: String?
    }

    func save() {
        guard !Demo.on else { return }
        lastSave = Date()
        let snapshot = samples
        let stored = events.map {
            StoredEvent(reason: $0.reason, severity: $0.severity, start: $0.start.timeIntervalSince1970,
                        duration: $0.duration, source: $0.source, detail: $0.detail)
        }
        let dir = storeURL
        saveUsage(to: dir)
        saveTracking(to: dir)
        Task.detached(priority: .utility) {
            let data = snapshot.withUnsafeBufferPointer { Data(buffer: $0) }
            try? data.write(to: dir.appendingPathComponent("samples.bin"), options: .atomic)
            if let json = try? JSONEncoder().encode(stored) {
                try? json.write(to: dir.appendingPathComponent("events.json"), options: .atomic)
            }
        }
    }

    private func load() {
        guard samples.isEmpty else { return }
        let dir = storeURL
        if let data = try? Data(contentsOf: dir.appendingPathComponent("samples.bin")),
           data.count % MemoryLayout<Sample>.stride == 0 {
            let cutoff = Int32(Date().timeIntervalSince1970) - Int32(Self.maxSamples)
            let all: [Sample] = data.withUnsafeBytes { Array($0.bindMemory(to: Sample.self)) }
            samples = all.filter { $0.t >= cutoff }
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("events.json")),
           let stored = try? JSONDecoder().decode([StoredEvent].self, from: data) {
            let cutoff = Date().addingTimeInterval(-7 * 86_400)
            events = stored
                .map { LinkEvent(reason: $0.reason, severity: $0.severity, start: Date(timeIntervalSince1970: $0.start),
                                 duration: $0.duration, source: $0.source, detail: $0.detail) }
                .filter { $0.start >= cutoff }
        }
        loadUsage(from: dir)
        loadTracking(from: dir)
    }

    func exportCSV() -> String {
        var out = "time,latency_ms,ping_drop_rate,downlink_bps,uplink_bps,power_w\n"
        let iso = ISO8601DateFormatter()
        for s in samples {
            out += "\(iso.string(from: s.date)),\(s.latency),\(s.drop),\(s.down),\(s.up),\(s.power)\n"
        }
        return out
    }
}
