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

        // 1. Initial DoH query
        let q1 = DNSPacket.buildAQuery(domain: "example.com", txID: 0x1111)
        if let res1 = await LocalDoHProxy.shared.resolveDNSQuery(q1) {
            assert(DNSPacket.transactionID(of: res1) == 0x1111)
            let ips1 = DNSPacket.extractARecords(from: res1)
            print("[Resolution] Initial DoH query for example.com: \(ips1.joined(separator: ", "))")
        }

        // 2. Cache hit query
        let q2 = DNSPacket.buildAQuery(domain: "example.com", txID: 0x2222)
        if let res2 = await LocalDoHProxy.shared.resolveDNSQuery(q2) {
            assert(DNSPacket.transactionID(of: res2) == 0x2222)
            assert(loggedRecords.last?.source == .cache, "Expected cache hit for second query")
            print("[Resolution] Second query served from CACHE: \(loggedRecords.last?.source.rawValue ?? "")")
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<MenuBarView>!
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var viewModel: AppViewModel!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide Dock icon so it behaves as a pure Menu Bar utility
        NSApp.setActivationPolicy(.accessory)

        viewModel = AppViewModel()

        hostingController = NSHostingController(
            rootView: MenuBarView(
                viewModel: viewModel,
                onOpenSettings: { [weak self] in
                    self?.openSettingsWindow()
                },
                onOpenHistory: { [weak self] in
                    self?.openHistoryWindow()
                }
            )
        )
        hostingController.sizingOptions = [.preferredContentSize]

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
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

    private func openSettingsWindow() {
        popover.performClose(nil)
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
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openHistoryWindow() {
        popover.performClose(nil)
        if historyWindow == nil {
            let controller = NSHostingController(rootView: HistoryView(viewModel: viewModel))
            let window = NSWindow(contentViewController: controller)
            window.title = "История DNS-запросов"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            historyWindow = window
        }
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateStatusBarButton(providerID: String?) {
        guard let button = statusItem.button else { return }
        if let id = providerID, let provider = viewModel.providers.first(where: { $0.id == id }) {
            button.image = NSImage(systemSymbolName: "network.badge.shield.half.filled", accessibilityDescription: "AI DNS Active")
            button.toolTip = "AI DNS Switcher • \(provider.name)"
        } else {
            button.image = NSImage(systemSymbolName: "network", accessibilityDescription: "DNS Default")
            button.toolTip = "AI DNS Switcher • Системный DNS"
        }
        button.title = ""
        button.imagePosition = .imageOnly
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            viewModel.refreshSystemState()
            hostingController.view.layoutSubtreeIfNeeded()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.handleAppTermination()
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
