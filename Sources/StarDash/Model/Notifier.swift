import Foundation
import UserNotifications

/// Turns state transitions into notifications. Sub-threshold blips stay silent:
/// Starlink drops for a second or two many times an hour and nobody wants a banner for each.
@MainActor
final class Notifier {
    private var downSince: Date?
    private var announcedDown = false
    private var knownAlerts: Set<String> = []
    private var primed = false
    private var announcedReboot = false

    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func observe(state: LinkState, dish: DishStatus?, settings: Settings) {
        let now = Date()

        if state.isUp {
            if let since = downSince, announcedDown, settings.notifyOutages {
                post("Starlink is back online", "Down for \(Fmt.duration(now.timeIntervalSince(since))).")
            }
            downSince = nil
            announcedDown = false
        } else if primed {
            if downSince == nil { downSince = now }
            if let since = downSince, !announcedDown, now.timeIntervalSince(since) >= settings.outageThreshold {
                announcedDown = true
                if settings.notifyOutages { post("Starlink is offline", state.title) }
            }
        }

        if let dish {
            let serious = Set(dish.alerts).subtracting(DishStatus.benignAlerts)
            if primed, settings.notifyAlerts {
                for alert in serious.subtracting(knownAlerts) { post("Starlink alert", alert) }
                if dish.softwareUpdateState == 6, !announcedReboot {
                    announcedReboot = true
                    post("Starlink update ready", "The dish will reboot to finish installing new firmware.")
                }
            }
            if dish.softwareUpdateState != 6 { announcedReboot = false }
            knownAlerts = serious
            primed = true
        }
    }

    // MARK: Link quality

    /// One threshold alert: posts when a value crosses its line, then waits for it to fall well back
    /// below before it can post again, and never more than once an hour.
    private struct Watch {
        var armed = true
        var lastPosted = Date.distantPast

        mutating func check(_ value: Double?, over threshold: Double, now: Date) -> Bool {
            guard threshold > 0, let value else { armed = true; return false }
            if value < threshold * 0.8 { armed = true }
            guard armed, value >= threshold, now.timeIntervalSince(lastPosted) >= 3600 else { return false }
            armed = false
            lastPosted = now
            return true
        }
    }

    private var latencyWatch = Watch()
    private var lossWatch = Watch()
    private var obstructionWatch = Watch()
    private var dataAnnouncedDay: Date?

    /// Alerts for a link that's up but poor, and for data use. Full outages are `observe`'s job.
    func watchQuality(store: TelemetryStore, settings: Settings) {
        guard primed, store.state.isUp, let dish = store.dish else { return }
        let now = Date()

        // The last five minutes, leaving out seconds that were outages.
        let live = store.window(300).filter { $0.drop < 1 }
        let enough = live.count >= 60
        let latency = enough ? live.reduce(0.0) { $0 + Double($1.latency) } / Double(live.count) : nil
        let loss = enough ? live.reduce(0.0) { $0 + Double($1.drop) } / Double(live.count) : nil

        if latencyWatch.check(latency, over: settings.alertLatencyMs, now: now), let latency {
            post("High latency", "Averaging \(Fmt.ms(latency)) over the last 5 minutes.")
        }
        if lossWatch.check(loss.map { $0 * 100 }, over: settings.alertLossPercent, now: now), let loss {
            post("Packet loss", "\(Fmt.percent(loss, digits: 0)) of packets lost over the last 5 minutes.")
        }
        let obstruction = dish.obstruction.fraction
        if obstructionWatch.check(obstruction.map { $0 * 100 }, over: settings.alertObstructionPercent, now: now) {
            post("Obstruction is up", "The dish is obstructed \(Fmt.percent(obstruction)) of the time. Check the Sky page.")
        }

        if settings.alertDataGB > 0 {
            let today = Calendar.current.startOfDay(for: now)
            let used = store.totals(MenuBarRenderer.hoursToday)
            if dataAnnouncedDay != today, used.down + used.up >= settings.alertDataGB * 1e9 {
                dataAnnouncedDay = today
                post("Data today", "\(Fmt.data(used.down + used.up)) used since midnight.")
            }
        }
    }

    private func post(_ title: String, _ body: String) {
        guard available, !Settings.shared.alertsPaused else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
