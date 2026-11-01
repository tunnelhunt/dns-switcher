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
    private var viewModel: AppViewModel!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide Dock icon so it behaves as a pure Menu Bar utility
        NSApp.setActivationPolicy(.accessory)

        viewModel = AppViewModel()

        hostingController = NSHostingController(
            rootView: MenuBarView(viewModel: viewModel, onOpenSettings: { [weak self] in
                self?.openSettingsWindow()
            })
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
            let controller = NSHostingController(rootView: SettingsView(viewModel: viewModel))
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
