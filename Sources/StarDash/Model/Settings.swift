import Foundation
import Observation
import ServiceManagement

enum MenuBarItem: String, CaseIterable, Identifiable, Codable {
    case latency, throughput, data, power, obstruction, events, sparkline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .latency: return "Latency"
        case .throughput: return "Throughput"
        case .data: return "Data today"
        case .power: return "Power draw"
        case .obstruction: return "Obstruction"
        case .events: return "Outages (last hour)"
        case .sparkline: return "Latency sparkline"
        }
    }
}

@Observable
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var menuBarItems: [MenuBarItem] { didSet { d.set(menuBarItems.map(\.rawValue), forKey: "menuBarItems") } }
    var showStatusDot: Bool { didSet { d.set(showStatusDot, forKey: "showStatusDot") } }
    var useBytes: Bool { didSet { d.set(useBytes, forKey: "useBytes") } }
    var pollInterval: Double { didSet { d.set(pollInterval, forKey: "pollInterval") } }
    var dishHost: String { didSet { d.set(dishHost, forKey: "dishHost") } }
    var routerHost: String { didSet { d.set(routerHost, forKey: "routerHost") } }
    var avoidTunnels: Bool { didSet { d.set(avoidTunnels, forKey: "avoidTunnels") } }
    var notifyOutages: Bool { didSet { d.set(notifyOutages, forKey: "notifyOutages") } }
    var notifyAlerts: Bool { didSet { d.set(notifyAlerts, forKey: "notifyAlerts") } }
    var outageThreshold: Double { didSet { d.set(outageThreshold, forKey: "outageThreshold") } }
    /// Link quality alerts. Zero turns each one off.
    var alertLatencyMs: Double { didSet { d.set(alertLatencyMs, forKey: "alertLatencyMs") } }
    var alertLossPercent: Double { didSet { d.set(alertLossPercent, forKey: "alertLossPercent") } }
    var alertObstructionPercent: Double { didSet { d.set(alertObstructionPercent, forKey: "alertObstructionPercent") } }
    var alertDataGB: Double { didSet { d.set(alertDataGB, forKey: "alertDataGB") } }
    var themeName: String { didSet { d.set(themeName, forKey: "theme") } }
    var openWindowAtLaunch: Bool { didSet { d.set(openWindowAtLaunch, forKey: "openWindowAtLaunch") } }
    /// Where the dish is, for working out which satellites are overhead. Kept to two decimals, about a kilometre.
    var siteLatitude: Double { didSet { d.set(siteLatitude, forKey: "siteLatitude") } }
    var siteLongitude: Double { didSet { d.set(siteLongitude, forKey: "siteLongitude") } }
    var hasSite: Bool { didSet { d.set(hasSite, forKey: "hasSite") } }
    /// Notifications stay quiet until this time, for when you know the link will be rough.
    var alertsPausedUntil: Date? { didSet { d.set(alertsPausedUntil?.timeIntervalSince1970, forKey: "alertsPausedUntil") } }
    var alertsPaused: Bool { (alertsPausedUntil ?? .distantPast) > Date() }
    /// What the speed test from this Mac runs against.
    var speedServer: SpeedServerChoice = SpeedServerChoice.saved { didSet { SpeedServerChoice.save(speedServer) } }

    func setSite(latitude: Double, longitude: Double) {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return }
        siteLatitude = (latitude * 100).rounded() / 100
        siteLongitude = (longitude * 100).rounded() / 100
        hasSite = true
    }

    private init() {
        d.register(defaults: [
            "menuBarItems": [MenuBarItem.latency.rawValue, MenuBarItem.throughput.rawValue],
            "showStatusDot": true,
            "useBytes": false,
            "pollInterval": 1.0,
            "dishHost": "192.168.100.1",
            "routerHost": "192.168.1.1",
            "avoidTunnels": true,
            "notifyOutages": true,
            "notifyAlerts": true,
            "outageThreshold": 10.0,
            "alertLatencyMs": 250.0,
            "alertLossPercent": 5.0,
            "alertObstructionPercent": 0.0,
            "alertDataGB": 0.0,
            "openWindowAtLaunch": true,
        ])
        menuBarItems = (d.stringArray(forKey: "menuBarItems") ?? []).compactMap(MenuBarItem.init(rawValue:))
        showStatusDot = d.bool(forKey: "showStatusDot")
        useBytes = d.bool(forKey: "useBytes")
        pollInterval = max(1, d.double(forKey: "pollInterval"))
        dishHost = d.string(forKey: "dishHost") ?? "192.168.100.1"
        routerHost = d.string(forKey: "routerHost") ?? "192.168.1.1"
        avoidTunnels = d.bool(forKey: "avoidTunnels")
        notifyOutages = d.bool(forKey: "notifyOutages")
        notifyAlerts = d.bool(forKey: "notifyAlerts")
        outageThreshold = d.double(forKey: "outageThreshold")
        alertLatencyMs = d.double(forKey: "alertLatencyMs")
        alertLossPercent = d.double(forKey: "alertLossPercent")
        alertObstructionPercent = d.double(forKey: "alertObstructionPercent")
        alertDataGB = d.double(forKey: "alertDataGB")
        openWindowAtLaunch = d.bool(forKey: "openWindowAtLaunch")
        themeName = d.string(forKey: "theme") ?? "glass"
        siteLatitude = d.double(forKey: "siteLatitude")
        siteLongitude = d.double(forKey: "siteLongitude")
        hasSite = d.bool(forKey: "hasSite")
        let paused = d.double(forKey: "alertsPausedUntil")
        alertsPausedUntil = paused > 0 ? Date(timeIntervalSince1970: paused) : nil
    }

    func toggle(_ item: MenuBarItem) {
        if let i = menuBarItems.firstIndex(of: item) {
            menuBarItems.remove(at: i)
        } else {
            // Keep a stable order regardless of the order things were enabled in.
            menuBarItems = MenuBarItem.allCases.filter { menuBarItems.contains($0) || $0 == item }
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("StarDash: launch at login failed: \(error.localizedDescription)")
            }
        }
    }
}
