import AppKit
import SwiftUI
import Combine

// 1. Check if launched as the privileged port-53 bridge daemon (`--bridge`)
if CommandLine.arguments.contains("--bridge") {
    Port53Bridge.runDaemon()
}

// 1b. Self-test mode (`--self-test`) to verify DoH resolution & TCP:443 proxy health from CLI
if CommandLine.arguments.contains("--self-test") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        let sysServers = SystemDNSManager.detectSystemAndVPNDNSServers(fallbackIP: "77.88.8.8")
        print("[System/VPN DNS] Detected bypass servers: \(sysServers.joined(separator: ", "))")

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
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<MenuBarView>!
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var viewModel: AppViewModel!
    private var windowDelegate: AppWindowDelegate!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide Dock icon so it behaves as a pure Menu Bar utility by default
        NSApp.setActivationPolicy(.accessory)

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

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = hostingController

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            updateStatusBarButton(providerID: viewModel.selectedProviderID)
        }

        viewModel.$selectedProviderID
            .receive(on: RunLoop.main)
            .sink { [weak self] providerID in
                self?.updateStatusBarButton(providerID: providerID)
            }
            .store(in: &cancellables)
    }

    private func showDockIcon() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func handleWindowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let hasVisible = (self.settingsWindow?.isVisible == true) || (self.historyWindow?.isVisible == true)
            if !hasVisible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = settingsWindow {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return true
        }
        return false
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
        popover.performClose(nil)
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
        popover.performClose(nil)
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

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            restoreSettingsWindowFocusIfNeeded()
        } else {
            let isSettingsOpen = (settingsWindow?.isVisible == true)
            let isSettingsKey = (settingsWindow?.isKeyWindow == true)
            let firstResponder = settingsWindow?.firstResponder

            viewModel.refreshSystemState()
            hostingController.view.layoutSubtreeIfNeeded()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)

            if isSettingsOpen {
                // Do NOT steal focus from settings window when clicking the tray icon
                if isSettingsKey, let settings = settingsWindow {
                    DispatchQueue.main.async {
                        settings.makeKey()
                        if let responder = firstResponder {
                            settings.makeFirstResponder(responder)
                        }
                    }
                }
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        restoreSettingsWindowFocusIfNeeded()
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
