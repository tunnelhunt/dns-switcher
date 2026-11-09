import AppKit
import SwiftUI
import Combine

// 1. Check if launched as the privileged port-53 bridge daemon (`--bridge`)
if CommandLine.arguments.contains("--bridge") {
    Port53Bridge.runDaemon()
}

// 1a. Query bridge version (`--bridge-version`)
if CommandLine.arguments.contains("--bridge-version") {
    print("\(Port53Bridge.bridgeVersion)")
    exit(0)
}

// 1b. Self-test mode (`--self-test`) to verify DoH resolution & TCP:443 proxy health from CLI
if CommandLine.arguments.contains("--self-test") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        let sysServers = SystemDNSManager.detectSystemAndVPNDNSServers(fallbackIP: "77.88.8.8")
        print("[System/VPN DNS] Detected bypass servers: \(sysServers.joined(separator: ", "))")
        let currentSysDNS = SystemDNSManager.currentSystemDNSServers()
        print("[Current System DNS] Detected configured DNS: \(currentSysDNS.joined(separator: ", "))")

        let rules = ["*.company.ru", "https://git.corp.local/repo", ".internal"].compactMap {
            SystemDNSManager.normalizeDomainRule($0)
        }
        assert(rules == ["company.ru", "git.corp.local", "internal"], "Normalization failed: \(rules)")
        assert(LocalDoHProxy.isDomainExcluded("jira.company.ru", excludedDomains: rules))
        assert(LocalDoHProxy.isDomainExcluded("company.ru", excludedDomains: rules))
        assert(LocalDoHProxy.isDomainExcluded("app.internal", excludedDomains: rules))
        assert(!LocalDoHProxy.isDomainExcluded("mycompany.ru", excludedDomains: rules))
        print("[Excluded Domains] Rule matching verified: \(rules.joined(separator: ", "))")

        // Test fallback disable configuration
        let disabledFallback = SystemDNSManager.resolveFallbackDNSServer(option: .disabled, customIP: "")
        assert(disabledFallback == "disabled")
        assert(Port53Bridge.currentFallbackDNSServer() == nil)
        print("[Fallback Config] Disabled fallback mode verified: no upstream fallback configured")

        // Test SERVFAIL synthesis
        let dummyQuery = DNSPacket.buildAQuery(domain: "test.local", txID: 0xABCD)
        let servfail = DNSPacket.buildFailureResponse(for: dummyQuery, rcode: 2)
        assert(DNSPacket.transactionID(of: servfail) == 0xABCD)
        assert(servfail[3] & 0x0F == 2, "Expected RCODE 2 (SERVFAIL)")
        print("[DNS Packet] SERVFAIL synthesis verified")

        // Test Cache and Disabled Fallback resolution flow
        var loggedRecords: [DNSResolutionRecord] = []
        LocalDoHProxy.shared.onResolutionLogged = { record in
            loggedRecords.append(record)
        }
        LocalDoHProxy.shared.setFallbackServer("disabled")
        LocalDoHProxy.shared.configure(active: DNSProvider.builtInProviders[0], all: DNSProvider.builtInProviders)

        // 1. Initial DoH query (if network available)
        let q1 = DNSPacket.buildAQuery(domain: "example.com", txID: 0x1111)
        if let res1 = await LocalDoHProxy.shared.resolveDNSQuery(q1),
           loggedRecords.last?.source == .doh {
            assert(DNSPacket.transactionID(of: res1) == 0x1111)
            let ips1 = DNSPacket.extractARecords(from: res1)
            print("[Resolution] Initial DoH query for example.com: \(ips1.joined(separator: ", "))")

            // 2. Cache hit query
            let q2 = DNSPacket.buildAQuery(domain: "example.com", txID: 0x2222)
            if let res2 = await LocalDoHProxy.shared.resolveDNSQuery(q2) {
                assert(DNSPacket.transactionID(of: res2) == 0x2222)
                assert(loggedRecords.last?.source == .cache, "Expected cache hit for second query")
                print("[Resolution] Second query served from CACHE: \(loggedRecords.last?.source.rawValue ?? "")")
            }
        }

        // 3. Query with broken provider and disabled fallback -> verify SERVFAIL returned, no fallback leak
        let brokenProvider = DNSProvider(
            id: "broken",
            name: "Broken",
            subtitle: "broken",
            dohURL: "https://127.0.0.1:54321/dns-query",
            dotHost: "broken",
            bootstrapIPs: [],
            plainDNSSupported: false,
            websiteURL: "",
            isBuiltIn: false
        )
        LocalDoHProxy.shared.configure(active: brokenProvider, all: [brokenProvider])
        let q3 = DNSPacket.buildAQuery(domain: "nonexistent-domain-test-12345.org", txID: 0x3333)
        if let res3 = await LocalDoHProxy.shared.resolveDNSQuery(q3) {
            assert(DNSPacket.transactionID(of: res3) == 0x3333)
            let rcode = res3[3] & 0x0F
            assert(rcode == 2, "Expected SERVFAIL (rcode 2) when DoH fails and fallback is disabled")
            assert(loggedRecords.last?.source == .error)
            print("[Resolution] Disabled fallback verified: returned SERVFAIL (RCODE \(rcode))")
        }

        for provider in DNSProvider.builtInProviders {
            let health = await LocalDoHProxy.shared.checkProviderHealth(provider)
            print("[\(provider.name)] DoH: \(provider.dohURL) -> \(health.badgeText)")
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// 2. Otherwise launch the Menu Bar GUI application
final class MenuBarPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class AppWindowDelegate: NSObject, NSWindowDelegate {
    private weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func windowWillClose(_ notification: Notification) {
        appDelegate?.handleWindowWillClose(notification)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: MenuBarPanel!
    private var hostingController: NSHostingController<MenuBarView>!
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var viewModel: AppViewModel!
    private var windowDelegate: AppWindowDelegate!
    private var cancellables = Set<AnyCancellable>()
    private var globalEventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.imagePosition = .imageOnly
            button.image = StatusIcon.image(isActive: false, size: 18)
            button.toolTip = "AI DNS Switcher"
        }

        // Ensure a high-resolution app icon is assigned for Dock & window headers
        if NSApp.applicationIconImage == nil {
            if let bundleIcon = NSImage(named: "AppIcon") {
                NSApp.applicationIconImage = bundleIcon
            } else {
                NSApp.applicationIconImage = StatusIcon.appIconImage(size: 256)
            }
        }

        windowDelegate = AppWindowDelegate(appDelegate: self)
        setupMainMenu()

        viewModel = AppViewModel()

        hostingController = NSHostingController(
            rootView: MenuBarView(
                viewModel: viewModel,
                onOpenSettings: { [weak self] in
                    self?.openSettingsWindow()
                }
            )
        )
        hostingController.sizingOptions = [.preferredContentSize]
        _ = hostingController.view

        panel = MenuBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentViewController = hostingController
        panel.onCancel = { [weak self] in
            self?.closePanel()
        }

        updateStatusBarButton(providerID: viewModel.selectedProviderID)

        viewModel.$selectedProviderID
            .receive(on: RunLoop.main)
            .sink { [weak self] providerID in
                self?.updateStatusBarButton(providerID: providerID)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceDidActivateApp(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    private func showDockIcon() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func handleWindowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let closedWindow = notification.object as? NSWindow {
                if closedWindow === self.historyWindow {
                    self.historyWindow = nil
                } else if closedWindow === self.settingsWindow {
                    self.settingsWindow = nil
                }
            }
            let hasVisible = (self.settingsWindow?.isVisible == true) || (self.historyWindow?.isVisible == true)
            if !hasVisible && !(self.viewModel?.alwaysShowInDock == true) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindow()
        return true
    }

    private func centerWindowOnActiveScreen(_ window: NSWindow) {
        window.layoutIfNeeded()
        let mouseLoc = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { NSMouseInRect(mouseLoc, $0.frame, false) }
            ?? NSScreen.main
            ?? window.screen
            ?? NSScreen.screens.first

        if let screen = targetScreen {
            let screenFrame = screen.visibleFrame
            let windowFrame = window.frame
            let x = screenFrame.origin.x + max(0, (screenFrame.width - windowFrame.width) / 2)
            let y = screenFrame.origin.y + max(0, (screenFrame.height - windowFrame.height) * 0.58)
            window.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
        } else {
            window.center()
        }
    }

    private func openSettingsWindow() {
        closePanel()
        showDockIcon()

        if settingsWindow == nil {
            let controller = NSHostingController(
                rootView: SettingsView(
                    viewModel: viewModel,
                    onOpenHistory: { [weak self] in
                        self?.openHistoryWindow()
                    }
                )
            )
            let window = NSWindow(contentViewController: controller)
            window.title = "Настройки AI DNS"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = windowDelegate
            settingsWindow = window
        }

        guard let window = settingsWindow else { return }
        window.makeKeyAndOrderFront(nil)
        centerWindowOnActiveScreen(window)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openHistoryWindow() {
        closePanel()
        showDockIcon()

        if historyWindow == nil {
            let controller = NSHostingController(rootView: HistoryView(viewModel: viewModel))
            let window = NSWindow(contentViewController: controller)
            window.title = "История DNS-запросов"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = windowDelegate
            historyWindow = window
        }

        guard let window = historyWindow else { return }
        window.makeKeyAndOrderFront(nil)
        centerWindowOnActiveScreen(window)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateStatusBarButton(providerID: String?) {
        guard let button = statusItem.button else { return }
        let isActive = (providerID != nil)
        button.image = StatusIcon.image(isActive: isActive, size: 18)
        button.imagePosition = .imageOnly
        button.title = ""

        if let id = providerID, let provider = viewModel.providers.first(where: { $0.id == id }) {
            button.image?.accessibilityDescription = "AI DNS Switcher • \(provider.name)"
            button.toolTip = "AI DNS Switcher • \(provider.name)"
        } else {
            button.image?.accessibilityDescription = "AI DNS Switcher • Выключен (Системный DNS)"
            button.toolTip = "AI DNS Switcher • Выключен (Системный DNS)"
        }
    }

    private var lastOpenTimestamp: TimeInterval = 0
    private var lastCloseTimestamp: TimeInterval = 0

    @objc private func togglePopover(_ sender: AnyObject?) {
        let now = ProcessInfo.processInfo.systemUptime

        if panel.isVisible {
            // Debounce fast clicks: if clicked again within 350ms of opening, ignore to prevent accidental close
            if now - lastOpenTimestamp < 0.35 {
                return
            }
            closePanel()
            return
        }

        if now - lastCloseTimestamp < 0.20 {
            return
        }

        showPanel()
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonBoundsInWindow = button.convert(button.bounds, to: nil)
        let buttonScreenRect = buttonWindow.convertToScreen(buttonBoundsInWindow)

        hostingController.view.layoutSubtreeIfNeeded()
        let panelSize = hostingController.view.fittingSize

        let targetScreen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let screenVisibleFrame = targetScreen.visibleFrame

        // Position horizontally centered under the icon, keep inside screen bounds
        var x = buttonScreenRect.midX - panelSize.width / 2.0
        x = max(screenVisibleFrame.minX + 8, min(x, screenVisibleFrame.maxX - panelSize.width - 8))

        // Position exactly 1px below the menu bar
        let y = screenVisibleFrame.maxY - panelSize.height - 1

        panel.setFrame(NSRect(x: round(x), y: round(y), width: panelSize.width, height: panelSize.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        lastOpenTimestamp = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.panel.isVisible else { return }
            self.startGlobalEventMonitor()
        }

        Task { [weak self] in
            self?.viewModel.refreshSystemState()
        }
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastCloseTimestamp = ProcessInfo.processInfo.systemUptime
        stopGlobalEventMonitor()
        restoreSettingsWindowFocusIfNeeded()
    }

    private func startGlobalEventMonitor() {
        guard globalEventMonitor == nil else { return }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.panel.isVisible else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.lastOpenTimestamp < 0.35 {
                    return
                }

                let mouseLoc = NSEvent.mouseLocation

                // If click is on our own menu bar status button, let button handle it
                if let button = self.statusItem.button, let win = button.window {
                    let windowPoint = win.convertPoint(fromScreen: mouseLoc)
                    let viewPoint = button.convert(windowPoint, from: nil)
                    if button.bounds.contains(viewPoint) {
                        return
                    }
                }

                // If click is inside the panel itself, don't close
                if self.panel.frame.contains(mouseLoc) {
                    return
                }

                self.closePanel()
            }
        }
    }

    private func stopGlobalEventMonitor() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
    }

    @objc private func handleAppDidResignActive() {
        if panel?.isVisible == true {
            closePanel()
        }
    }

    @objc private func handleWorkspaceDidActivateApp(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            if panel?.isVisible == true {
                closePanel()
            }
        }
    }

    private func restoreSettingsWindowFocusIfNeeded() {
        if let window = settingsWindow, window.isVisible {
            DispatchQueue.main.async {
                window.makeKey()
            }
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "О программе AI DNS Switcher", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Завершить AI DNS Switcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit Menu (Enables ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z in all TextFields)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Правка")
        editMenu.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Повторить", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window Menu (⌘W to close active window)
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Окно")
        windowMenu.addItem(withTitle: "Закрыть", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.handleAppTermination()
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
