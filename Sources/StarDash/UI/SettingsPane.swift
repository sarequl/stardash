import SwiftUI
import UniformTypeIdentifiers

/// Settings page in the main window. The popover keeps the compact `SettingsView`.
struct SettingsPane: View {
    @Environment(TelemetryStore.self) private var store
    @Environment(SpeedTest.self) private var speedTest
    @State private var launchAtLogin = Settings.shared.launchAtLogin
    @State private var exportNote: String?

    var body: some View {
        @Bindable var settings = Settings.shared

        PaneScroll {
            PaneTitle("Settings")
            menuBar(settings)
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    notifications(settings)
                    general(settings)
                    StarlinkAccountPanel()
                }
                VStack(spacing: 14) {
                    connection(settings)
                    data
                    UpdatesPanel()
                }
            }
            footer
        }
        .toggleStyle(ThemedSwitch())
        .buttonStyle(QuietButton())
    }

    // MARK: Appearance

    private func appearance(_ settings: Settings) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Kicker("Theme")
                HStack(spacing: 12) {
                    ForEach(AppTheme.allCases) { theme in
                        ThemeCard(theme: theme, selected: Theme.current == theme) {
                            settings.themeName = theme.rawValue
                        }
                    }
                }
            }
        }
    }

    // MARK: Menu bar

    private func menuBar(_ settings: Settings) -> some View {
        @Bindable var settings = settings
        return Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                MenuBarPreview(store: store, settings: settings)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Kicker("Show in the menu bar")
                        Spacer()
                        Text("Click to add or remove. Turn them all off for just the icon.")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(MenuBarItem.allCases) { item in
                            Chip(icon: icon(item), label: item.label, on: settings.menuBarItems.contains(item)) {
                                withAnimation(.spring(duration: 0.3, bounce: 0.3)) { settings.toggle(item) }
                            }
                        }
                    }
                    HStack(spacing: 28) {
                        Toggle("Color the dish by status", isOn: $settings.showStatusDot)
                        HStack(spacing: 10) {
                            Text("Speed in")
                            ChipPicker(options: [(false, "Mbps"), (true, "MB/s")], selection: $settings.useBytes)
                        }
                        Spacer()
                    }
                    .font(.system(size: 12.5))
                    .padding(.top, 2)
                }
                .padding(16)
            }
        }
    }

    private func icon(_ item: MenuBarItem) -> String {
        switch item {
        case .latency: return "timer"
        case .throughput: return "arrow.up.arrow.down"
        case .data: return "internaldrive"
        case .power: return "bolt"
        case .obstruction: return "tree"
        case .events: return "exclamationmark.triangle"
        case .sparkline: return "waveform.path.ecg"
        }
    }

    // MARK: Groups

    private func notifications(_ settings: Settings) -> some View {
        @Bindable var settings = settings
        return Panel(padding: 0) {
            VStack(spacing: 0) {
                GroupTitle("Notifications")
                SettingRow(icon: "bolt.slash.fill", tint: Palette.bad, title: "Outages and recovery",
                           detail: "A note when the link drops and when it's back") {
                    Toggle("", isOn: $settings.notifyOutages).labelsHidden()
                }
                SettingRow(icon: "timer", tint: Palette.warn, title: "Ignore short blips",
                           detail: "Outages shorter than this stay quiet") {
                    DropPicker(options: [(5.0, "5 seconds"), (10.0, "10 seconds"), (30.0, "30 seconds"), (60.0, "1 minute")],
                               selection: $settings.outageThreshold)
                }
                SettingRow(icon: "bell.badge.fill", tint: Palette.power, title: "Dish alerts and firmware",
                           detail: "Overheating, slow Ethernet, new firmware") {
                    Toggle("", isOn: $settings.notifyAlerts).labelsHidden()
                }
                SettingRow(icon: "gauge.with.needle.fill", tint: Palette.warn, title: "High latency",
                           detail: "Average over the last 5 minutes") {
                    DropPicker(options: [(0.0, "Off"), (100.0, "100 ms"), (150.0, "150 ms"), (250.0, "250 ms")],
                               selection: $settings.alertLatencyMs)
                }
                SettingRow(icon: "waveform.path.badge.minus", tint: Palette.bad, title: "Packet loss",
                           detail: "Over the last 5 minutes, outages aside") {
                    DropPicker(options: [(0.0, "Off"), (2.0, "2%"), (5.0, "5%"), (10.0, "10%")],
                               selection: $settings.alertLossPercent)
                }
                SettingRow(icon: "tree.fill", tint: Palette.good, title: "Obstruction",
                           detail: "Share of time the dish's view is blocked") {
                    DropPicker(options: [(0.0, "Off"), (1.0, "1%"), (3.0, "3%"), (5.0, "5%")],
                               selection: $settings.alertObstructionPercent)
                }
                SettingRow(icon: "chart.bar.fill", tint: Palette.accent, title: "Daily data",
                           detail: "Once a day, when today's use passes this") {
                    DropPicker(options: [(0.0, "Off"), (10.0, "10 GB"), (25.0, "25 GB"), (50.0, "50 GB"), (100.0, "100 GB")],
                               selection: $settings.alertDataGB)
                }
            }
        }
    }

    private func general(_ settings: Settings) -> some View {
        @Bindable var settings = settings
        return Panel(padding: 0) {
            VStack(spacing: 0) {
                GroupTitle("General")
                SettingRow(icon: "power", tint: Palette.good, title: "Launch at login",
                           detail: "StarDash sits in the menu bar from startup") {
                    Toggle("", isOn: $launchAtLogin).labelsHidden()
                        .onChange(of: launchAtLogin) { _, value in
                            settings.launchAtLogin = value
                            launchAtLogin = settings.launchAtLogin
                        }
                }
                SettingRow(icon: "macwindow", tint: Palette.accent, title: "Open this window at launch",
                           detail: "Off keeps StarDash menu bar only until you ask") {
                    Toggle("", isOn: $settings.openWindowAtLaunch).labelsHidden()
                }
            }
        }
    }

    private func connection(_ settings: Settings) -> some View {
        @Bindable var settings = settings
        return Panel(padding: 0) {
            VStack(spacing: 0) {
                GroupTitle("Connection")
                SettingRow(icon: "antenna.radiowaves.left.and.right", tint: Palette.accent, title: "Dish address",
                           detail: store.dish != nil ? "Connected" : (store.dishError ?? "Not answering"),
                           detailColor: store.dish != nil ? Palette.good : Palette.bad) {
                    AddressField(placeholder: "192.168.100.1", text: $settings.dishHost)
                }
                SettingRow(icon: "wifi.router", tint: Palette.up, title: "Router address",
                           detail: store.router != nil ? "Connected" : "Not answering (normal without a Starlink router)",
                           detailColor: store.router != nil ? Palette.good : .white.opacity(0.45)) {
                    AddressField(placeholder: "192.168.1.1", text: $settings.routerHost)
                }
                SettingRow(icon: "location", tint: Palette.accent, title: "Dish location",
                           detail: store.dishLocation != nil ? "Shared by the dish itself"
                               : settings.hasSite ? "Used to work out which satellites are overhead. Kept to about a kilometre, on this Mac only."
                               : "Latitude, longitude. Needed to show satellites on the Sky page.") {
                    SiteField()
                }
                SettingRow(icon: "lock.shield", tint: Palette.good, title: "Reach the dish around VPNs",
                           detail: "VPN apps often capture the dish's address. On, StarDash talks over Wi-Fi or Ethernet directly.") {
                    Toggle("", isOn: $settings.avoidTunnels).labelsHidden()
                }
                SettingRow(icon: "arrow.triangle.2.circlepath", tint: Palette.power, title: "Refresh when closed",
                           detail: "How often the menu bar updates. Open windows always refresh every second.") {
                    DropPicker(options: [(1.0, "Every second"), (2.0, "Every 2 seconds"), (5.0, "Every 5 seconds"), (15.0, "Every 15 seconds")],
                               selection: $settings.pollInterval)
                }
            }
        }
    }

    private var data: some View {
        Panel(padding: 0) {
            VStack(spacing: 0) {
                GroupTitle("Your data")
                SettingRow(icon: "chart.xyaxis.line", tint: Palette.accent, title: "Link history",
                           detail: exportNote ?? "\(store.samples.count.formatted()) samples, up to 24 hours") {
                    Button("Export CSV…") { export() }
                }
                SettingRow(icon: "speedometer", tint: Palette.up, title: "Speed test history",
                           detail: speedTest.history.isEmpty ? "No runs saved" : "\(speedTest.history.count) runs saved") {
                    Button("Clear") { speedTest.clearHistory() }.disabled(speedTest.history.isEmpty)
                }
                Text("Everything stays on this Mac. Nothing is uploaded.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("StarDash is independent and not affiliated with Starlink or SpaceX.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.3))
            Spacer()
            Button("Quit StarDash") { NSApp.terminate(nil) }
        }
        .padding(.top, 4)
        .padding(.horizontal, 4)
    }

    private func export() {
        let csv = store.exportCSV()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "starlink-history.csv"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            exportNote = "Saved to \(url.lastPathComponent)"
        } catch {
            exportNote = "Export failed: \(error.localizedDescription)"
        }
    }
}

/// A mock menu bar showing exactly what the real one will display.
private struct MenuBarPreview: View {
    var store: TelemetryStore
    var settings: Settings

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "apple.logo").font(.system(size: 13))
            Text("Finder").font(.system(size: 13, weight: .semibold))
            Text("File").font(.system(size: 13))
            Text("Edit").font(.system(size: 13))
            Spacer()
            HStack(spacing: 6) {
                if settings.showStatusDot {
                    Image(nsImage: MenuBarRenderer.logo(online: store.state.isUp, color: Palette.nsState(store.state)))
                }
                Image(nsImage: MenuBarRenderer.image(store: store, settings: settings, leadingInset: 0,
                                                     logo: settings.showStatusDot ? .none : .inline))
                    .renderingMode(.template)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.r(6), style: .continuous))
            Image(systemName: "wifi").font(.system(size: 13))
            Image(systemName: "battery.75").font(.system(size: 15))
            Text("9:41").font(.system(size: 13)).monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 18)
        .frame(height: 54)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: Theme.isMono ? [.white.opacity(0.10), .white.opacity(0.10)] : [Palette.accent.opacity(0.32), Palette.up.opacity(0.22)],
                           startPoint: .leading, endPoint: .trailing)
        )
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.r(18), topTrailingRadius: Theme.r(18), style: .continuous))
    }
}

private struct Chip: View {
    var icon: String
    var label: String
    var on: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark" : icon).font(.system(size: 10, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .foregroundStyle(on ? Theme.onAccent : .white.opacity(0.6))
            .background(on ? Palette.accent.opacity(0.85) : .white.opacity(hovering ? 0.12 : 0.07), in: Pillow())
            .overlay(Pillow().strokeBorder(.white.opacity(on ? 0.3 : 0.1)))
            .contentShape(Pillow())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
    }
}

struct GroupTitle: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Kicker(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }
}

struct SettingRow<Control: View>: View {
    var icon: String
    var tint: Color
    var title: String
    var detail: String
    var detailColor: Color = .white.opacity(0.45)
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            if Theme.isMono {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .overlay(Rectangle().strokeBorder(.white.opacity(0.22)))
            } else {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 56)
        }
    }
}

struct AddressField: View {
    var placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 150)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous).strokeBorder(.white.opacity(0.1)))
    }
}

/// Latitude and longitude typed as one pair, such as "47.60, -122.30".
private struct SiteField: View {
    @State private var text = Demo.on ? String(format: "%.2f, %.2f", Demo.site.latitude, Demo.site.longitude)
        : Settings.shared.hasSite ? String(format: "%.2f, %.2f", Settings.shared.siteLatitude, Settings.shared.siteLongitude) : ""

    var body: some View {
        AddressField(placeholder: "47.60, -122.30", text: $text)
            .onChange(of: text) { _, value in
                // Demo mode shows a stand-in location and never saves over the real one.
                guard !Demo.on else { return }
                let parts = value.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
                if parts.count == 2 {
                    Settings.shared.setSite(latitude: parts[0], longitude: parts[1])
                } else if value.trimmingCharacters(in: .whitespaces).isEmpty {
                    Settings.shared.hasSite = false
                }
            }
            .onChange(of: Settings.shared.hasSite) { _, has in
                // Filled in from elsewhere, such as the Sky page's "use this Mac's location".
                if has, text.isEmpty, !Demo.on { text = String(format: "%.2f, %.2f", Settings.shared.siteLatitude, Settings.shared.siteLongitude) }
            }
    }
}

/// A small mock of each theme, so the choice is made by looking.
private struct ThemeCard: View {
    var theme: AppTheme
    var selected: Bool
    var action: () -> Void

    var body: some View {
        let mono = theme == .mono
        let radius: CGFloat = mono ? 2 : 10
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(mono ? AnyShapeStyle(Color.black)
                                   : AnyShapeStyle(LinearGradient(colors: [Color(red: 0.05, green: 0.16, blue: 0.12), .black],
                                                                  startPoint: .topTrailing, endPoint: .bottomLeading)))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(mono ? "ONLINE" : "Online")
                            .font(mono ? .custom("DIN Alternate", fixedSize: 13) : .system(size: 14, weight: .thin))
                            .kerning(mono ? 1.5 : 0)
                        HStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { i in
                                RoundedRectangle(cornerRadius: mono ? 1 : 4, style: .continuous)
                                    .fill(.white.opacity(mono ? 0.0 : 0.10))
                                    .overlay(RoundedRectangle(cornerRadius: mono ? 1 : 4, style: .continuous).strokeBorder(.white.opacity(mono ? 0.3 : 0.14)))
                                    .overlay(alignment: .bottomLeading) {
                                        Rectangle()
                                            .fill(mono ? Color.white : [Color(red: 0.30, green: 0.62, blue: 1.0), Color(red: 0.24, green: 0.80, blue: 0.52), Color(red: 0.72, green: 0.52, blue: 1.0)][i])
                                            .frame(width: 10 + CGFloat(i) * 4, height: 2)
                                            .padding(4)
                                    }
                                    .frame(height: 20)
                            }
                        }
                    }
                    .padding(9)
                }
                .frame(width: 128, height: 70)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.18)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(theme.title).font(.system(size: 14, weight: .semibold))
                    Text(theme.detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Palette.accent : .white.opacity(0.25))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(selected ? 0.07 : 0.03), in: RoundedRectangle(cornerRadius: Theme.r(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(14), style: .continuous).strokeBorder(selected ? Palette.accent : .white.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }
}
