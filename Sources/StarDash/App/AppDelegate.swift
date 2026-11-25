import AppKit
import SwiftUI
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    let store = TelemetryStore()
    let speedTest = SpeedTest()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    /// The dish logo in the link state's color, laid over the template readout so the text keeps the menu bar's tint.
    private let statusLogo = NSImageView()
    private let actions = AppActions()
    private var window: NSWindow?

    /// `--pane sky` opens the window on a given pane. Handy for profiling one screen.
    private static var launchPane: Pane {
        guard let i = CommandLine.arguments.firstIndex(of: "--pane"), i + 1 < CommandLine.arguments.count else { return .overview }
        return Pane(rawValue: CommandLine.arguments[i + 1]) ?? .overview
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            statusLogo.imageScaling = .scaleNone
            button.addSubview(statusLogo)
        }

        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = PopoverRoot.size
        popover.contentViewController = NSHostingController(
            rootView: PopoverRoot().environment(store).environment(speedTest).environment(actions)
        )
        actions.openMainWindow = { [weak self] in
            self?.popover.performClose(nil)
            self?.showWindow()
        }
        actions.openSettings = { [weak self] in self?.openSettings() }

        store.notifier.requestAuthorization()
        store.start()
        RulesEngine.shared.start(store: store)
        AppUpdater.shared.start()
        render()
        if Driver.directory != nil {
            showWindow()
            if let window { Task { await Driver.run(window: window, showPane: { [actions] pane in actions.showPane(pane) }) } }
        } else if Settings.shared.openWindowAtLaunch {
            showWindow()
        }
    }

    // MARK: Main window

    /// The app lives in the menu bar. It only takes a Dock icon while the window is open.
    func showWindow() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            w.title = "StarDash"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.backgroundColor = .black
            w.appearance = NSAppearance(named: .darkAqua)
            w.isMovableByWindowBackground = false
            w.minSize = NSSize(width: 940, height: 640)
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(
                rootView: MainWindow(pane: Self.launchPane).environment(store).environment(speedTest).environment(actions)
            )
            w.setContentSize(NSSize(width: 1080, height: 760))
            w.center()
            w.setFrameAutosaveName("StarDashMain")
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        store.windowOpen = true
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        store.windowOpen = false
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    /// Redraws the menu bar whenever anything the renderer read changes.
    private func render() {
        withObservationTracking {
            guard let button = statusItem.button else { return }
            let settings = Settings.shared
            let colored = settings.showStatusDot
            let image = MenuBarRenderer.image(store: store, settings: settings, leadingInset: 0,
                                              logo: colored ? .space : .inline)
            button.image = image
            statusItem.length = image.size.width + 12
            statusLogo.isHidden = !colored
            if colored {
                let logo = MenuBarRenderer.logo(online: store.state.isUp, color: Palette.nsState(store.state))
                statusLogo.image = logo
                statusLogo.frame = NSRect(x: 6, y: (button.bounds.height - logo.size.height) / 2,
                                          width: logo.size.width, height: logo.size.height)
            }
            button.toolTip = tooltip
        } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
    }

    private var tooltip: String {
        guard let dish = store.dish, store.dishError == nil else { return "StarDash: dish unreachable" }
        return "\(dish.modelName): \(store.state.title)"
    }

    private func openSettings() {
        popover.performClose(nil)
        showWindow()
        // A window that was just created needs a moment before it can be told which page to show.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [actions] in actions.showPane(.settings) }
    }

    /// Right-click: the few things worth doing without opening anything.
    private func showMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        add("Open StarDash", #selector(menuOpen))
        add(speedTest.isRunning ? "Speed Test Running…" : "Run Speed Test", #selector(menuSpeedTest))
        add("Settings…", #selector(menuSettings), key: ",")
        if AppUpdater.shared.isAvailable { add("Check for Updates…", #selector(menuCheckUpdates)) }
        menu.addItem(.separator())
        add("Quit StarDash", #selector(menuQuit), key: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpen() { showWindow() }
    @objc private func menuSettings() { openSettings() }
    /// Checks, then shows the result in Settings, where the update panel lives.
    @objc func menuCheckUpdates() {
        AppUpdater.shared.check()
        openSettings()
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    @objc private func menuSpeedTest() {
        guard !speedTest.isRunning else { return }
        Task { await speedTest.run(store: store) }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            showMenu()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.popoverOpen = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        store.popoverOpen = false
    }
}

extension AppDelegate {
    /// macOS sends ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z through the Edit menu, so without one those shortcuts do nothing
    /// in text fields and on the Starlink sign-in page. The menus show while the main window is open.
    func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        func add(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            edit.addItem(item)
        }
        add("Undo", Selector(("undo:")), "z")
        add("Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add("Cut", #selector(NSText.cut(_:)), "x")
        add("Copy", #selector(NSText.copy(_:)), "c")
        add("Paste", #selector(NSText.paste(_:)), "v")
        add("Select All", #selector(NSText.selectAll(_:)), "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let app = NSMenu(title: "StarDash")
        let settings = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        app.addItem(settings)
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(menuCheckUpdates), keyEquivalent: "")
        updates.target = self
        app.addItem(updates)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide StarDash", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        app.addItem(NSMenuItem(title: "Quit StarDash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem(title: "StarDash", action: nil, keyEquivalent: "")
        appItem.submenu = app
        let main = NSMenu()
        main.addItem(appItem)
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
