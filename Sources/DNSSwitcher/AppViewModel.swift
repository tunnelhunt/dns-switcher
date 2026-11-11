import Foundation
import SwiftUI
import AppKit

@MainActor
public final class AppViewModel: ObservableObject {
    @Published public var providers: [DNSProvider] = []
    @Published public var selectedProviderID: String? = nil
    @Published public var healthMap: [String: ProviderHealth] = [:]
    @Published public var isBridgeInstalled: Bool = false
    @Published public var isBridgeUpToDate: Bool = true
    @Published public var hasConflictingProfile: Bool = false
    @Published public var autoFailoverEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(autoFailoverEnabled, forKey: "autoFailoverEnabled")
        }
    }
    @Published public var alwaysShowInDock: Bool = false {
        didSet {
            UserDefaults.standard.set(alwaysShowInDock, forKey: "alwaysShowInDock")
            applyDockPolicy()
        }
    }
    @Published public var resetDNSOnQuit: Bool = true {
        didSet {
            UserDefaults.standard.set(resetDNSOnQuit, forKey: "resetDNSOnQuit")
        }
    }
    @Published public var fallbackOption: FallbackDNSOption = .system {
        didSet {
            UserDefaults.standard.set(fallbackOption.rawValue, forKey: fallbackOptionKey)
            applyFallbackDNSConfiguration()
        }
    }
    @Published public var customFallbackIP: String = "" {
        didSet {
            UserDefaults.standard.set(customFallbackIP, forKey: customFallbackIPKey)
            if fallbackOption == .custom {
                applyFallbackDNSConfiguration()
            }
        }
    }
    @Published public var resolvedFallbackIP: String = "77.88.8.8"
    @Published public var excludedDomains: [String] = []
    @Published public var statusMessage: String = "Готов к работе"
    @Published public var activeModeText: String = "Системный DNS (по умолчанию)"
    @Published public var isCheckingAll: Bool = false
    @Published public var consecutiveFailures: Int = 0

    public var resolutionHistory: [DNSResolutionRecord] {
        DNSHistoryStore.shared.records
    }
    public var resolvedCount: Int {
        DNSHistoryStore.shared.totalResolvedCount
    }
    public var maxHistoryCount: Int {
        DNSHistoryStore.shared.maxHistoryCount
    }

    public var activeProviderHealth: ProviderHealth {
        guard let id = selectedProviderID else { return .unknown }
        return healthMap[id] ?? .unknown
    }

    private final class FailureTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var count: Int = 0

        func record(isSuccess: Bool) -> Int {
            lock.lock()
            defer { lock.unlock() }
            if isSuccess {
                count = 0
                return 0
            } else {
                count += 1
                return count
            }
        }
    }
    private let failureTracker = FailureTracker()

    private let allProvidersKey = "allDNSProviders_v2"
    private let customProvidersKey = "customDNSProviders"
    private let lastProviderKey = "lastSelectedProviderID"
    private let fallbackOptionKey = "fallbackDNSOption"
    private let customFallbackIPKey = "customFallbackDNSIP"
    private let excludedDomainsKey = "excludedDNSDomains"

    public init() {
        loadProviders()
        loadExcludedDomains()
        self.autoFailoverEnabled = UserDefaults.standard.bool(forKey: "autoFailoverEnabled")
        self.alwaysShowInDock = UserDefaults.standard.bool(forKey: "alwaysShowInDock")
        applyDockPolicy()
        if UserDefaults.standard.object(forKey: "resetDNSOnQuit") != nil {
            self.resetDNSOnQuit = UserDefaults.standard.bool(forKey: "resetDNSOnQuit")
        }
        if let rawOption = UserDefaults.standard.string(forKey: fallbackOptionKey),
           let parsedOption = FallbackDNSOption(rawValue: rawOption) {
            self.fallbackOption = parsedOption
        }
        if let savedCustomIP = UserDefaults.standard.string(forKey: customFallbackIPKey) {
            self.customFallbackIP = savedCustomIP
        }
        applyFallbackDNSConfiguration()

        LocalDoHProxy.shared.onQueryResolved = nil
        LocalDoHProxy.shared.onResolutionLogged = { [weak self] record in
            DNSHistoryStore.shared.logRecord(record)
            self?.handleQueryResolution(isSuccess: record.isSuccess, serverName: record.serverName)
        }
        LocalDoHProxy.shared.startIfNeeded()

        NetworkStateMonitor.shared.start { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleNetworkChange()
            }
        }

        refreshSystemState()
        Task {
            await checkAllProvidersHealth()
        }
    }

    public var activeProvider: DNSProvider? {
        guard let id = selectedProviderID else { return nil }
        return providers.first(where: { $0.id == id })
    }

    public var shortStatusText: String {
        if let provider = activeProvider {
            return isBridgeInstalled ? "\(provider.name) • DoH" : "\(provider.name) • IPv4"
        }
        return "Выключен (системный)"
    }

    public func enableLastOrDefaultProvider() {
        let savedID = UserDefaults.standard.string(forKey: lastProviderKey)
        let available = providers.filter { $0.isEnabledInMenuBar }
        let listToPick = available.isEmpty ? providers : available
        if let id = savedID, let provider = listToPick.first(where: { $0.id == id }) {
            selectProvider(provider)
        } else if let first = listToPick.first {
            selectProvider(first)
        }
    }

    public func applyDockPolicy() {
        if alwaysShowInDock {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
        }
    }

    public func applyFallbackDNSConfiguration() {
        let resolved = SystemDNSManager.resolveFallbackDNSServer(option: fallbackOption, customIP: customFallbackIP)
        self.resolvedFallbackIP = (fallbackOption == .disabled) ? "Отключен" : resolved
        LocalDoHProxy.shared.setFallbackServer(resolved)
    }

    public func clearHistory() {
        DNSHistoryStore.shared.clear()
    }

    @MainActor
    public func handleNetworkChange() {
        SystemDNSManager.clearCaches()
        LocalDoHProxy.shared.resetNetworkConnections()

        guard let active = self.activeProvider else {
            refreshSystemState()
            return
        }

        let actual = SystemDNSManager.currentSystemDNSServers()
        if !actual.contains("127.0.0.1") {
            // Re-apply 127.0.0.1 asynchronously so MainActor is not blocked by subprocess
            Task.detached(priority: .userInitiated) {
                SystemDNSManager.setSystemDNS(servers: ["127.0.0.1"])
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.refreshSystemState()
                    let isVPN = SystemDNSManager.hasActiveVPNIPv4Interface()
                    if isVPN {
                        self.statusMessage = "DoH активен • OpenVPN подключен (Split-DNS)"
                    } else {
                        self.statusMessage = "DoH активен (\(active.name))"
                    }
                }
            }
        } else {
            refreshSystemState()
        }
    }

    public func refreshSystemState() {
        applyFallbackDNSConfiguration()
        isBridgeInstalled = Port53Bridge.isBridgeRunning()
        isBridgeUpToDate = isBridgeInstalled && SystemDNSManager.isBridgeBinaryUpToDate()
        hasConflictingProfile = SystemDNSManager.hasActiveMobileConfigDNSProfile()
        let currentServers = SystemDNSManager.currentSystemDNSServers()

        if currentServers.contains("127.0.0.1") {
            let savedID = UserDefaults.standard.string(forKey: lastProviderKey) ?? providers.first?.id
            selectedProviderID = savedID
            if let provider = activeProvider {
                LocalDoHProxy.shared.configure(active: provider, all: providers)
                let isVPN = SystemDNSManager.hasActiveVPNIPv4Interface()
                if isVPN {
                    activeModeText = "Активен DoH • \(provider.name) (VPN активен)"
                    statusMessage = "DoH 127.0.0.1 + Split-DNS для VPN"
                } else {
                    activeModeText = "Активен DoH • \(provider.name)"
                    statusMessage = "Трафик DNS зашифрован (DoH 127.0.0.1)"
                }
            }
        } else if let matched = providers.first(where: { !$0.bootstrapIPs.isEmpty && currentServers.first == $0.bootstrapIPs.first }) {
            selectedProviderID = matched.id
            activeModeText = "Активен IPv4 • \(matched.name)"
            statusMessage = "Прямой DNS: \(currentServers.joined(separator: ", "))"
        } else {
            selectedProviderID = nil
            if currentServers.isEmpty {
                activeModeText = "Системный DNS (DHCP роутера)"
            } else {
                activeModeText = "Сторонний DNS: \(currentServers.joined(separator: ", "))"
            }
        }
    }

    public func selectProvider(_ provider: DNSProvider) {
        LocalDoHProxy.shared.configure(active: provider, all: providers)
        UserDefaults.standard.set(provider.id, forKey: lastProviderKey)

        // Check if our 127.0.0.1:53 bridge is active
        if Port53Bridge.isBridgeRunning() {
            isBridgeInstalled = true
            let ok = SystemDNSManager.setSystemDNS(servers: ["127.0.0.1"])
            selectedProviderID = provider.id
            activeModeText = "Активен DoH • \(provider.name)"
            statusMessage = ok
                ? "Переключено на \(provider.name) (DoH)"
                : "Ошибка применения настроек сети"
            return
        }

        // Bridge is not installed yet — prompt 1-time installation
        statusMessage = "Установка системного DoH-моста (1 раз)…"
        Task {
            let installResult = await Task.detached(priority: .userInitiated) {
                SystemDNSManager.installPort53BridgeDaemon()
            }.value

            // Wait up to 800ms for launchd to bind 127.0.0.1:53
            for _ in 0..<8 {
                if Port53Bridge.isBridgeRunning() { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            let bridgeReady = Port53Bridge.isBridgeRunning()
            self.isBridgeInstalled = bridgeReady

            if bridgeReady {
                _ = SystemDNSManager.setSystemDNS(servers: ["127.0.0.1"])
                self.selectedProviderID = provider.id
                self.activeModeText = "Активен DoH • \(provider.name)"
                self.statusMessage = "DoH-мост установлен! Активен \(provider.name)"
            } else if provider.plainDNSSupported && !provider.bootstrapIPs.isEmpty {
                // Fallback to plain IPv4 DNS if user cancelled password prompt and provider supports plain port 53
                let ips = Array(provider.bootstrapIPs.prefix(2))
                _ = SystemDNSManager.setSystemDNS(servers: ips)
                self.selectedProviderID = provider.id
                self.activeModeText = "Активен IPv4 • \(provider.name)"
                self.statusMessage = "Включён прямой IPv4 для \(provider.name) (без DoH-моста)"
            } else {
                if case .failure(let err) = installResult {
                    self.statusMessage = "Для \(provider.name) нужен DoH-мост: \(err.localizedDescription)"
                } else {
                    self.statusMessage = "Не удалось запустить DoH-мост на 127.0.0.1:53"
                }
            }
        }
    }

    public func disableCustomDNS() {
        _ = SystemDNSManager.resetToSystemDefault()
        LocalDoHProxy.shared.clearCache()
        selectedProviderID = nil
        activeModeText = "Системный DNS (DHCP роутера)"
        statusMessage = "Возвращён стандартный системный DNS"
    }

    public func installBridgeManually() {
        statusMessage = "Запрос прав для установки DoH-моста…"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                SystemDNSManager.installPort53BridgeDaemon()
            }.value
            for _ in 0..<8 {
                if Port53Bridge.isBridgeRunning() { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self.isBridgeInstalled = Port53Bridge.isBridgeRunning()
            switch result {
            case .success:
                self.isBridgeInstalled = Port53Bridge.isBridgeRunning()
                self.isBridgeUpToDate = self.isBridgeInstalled && SystemDNSManager.isBridgeBinaryUpToDate()
                self.statusMessage = self.isBridgeInstalled
                    ? "DoH-мост (127.0.0.1:53) успешно обновлён и запущен!"
                    : "Служба установлена, проверьте статус"
                if let current = self.activeProvider {
                    self.selectProvider(current)
                }
            case .failure(let err):
                self.statusMessage = "Установка отменена: \(err.localizedDescription)"
            }
        }
    }

    public func uninstallBridgeManually() {
        Task {
            _ = await Task.detached(priority: .userInitiated) {
                SystemDNSManager.uninstallPort53BridgeDaemon()
            }.value
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.isBridgeInstalled = Port53Bridge.isBridgeRunning()
            self.isBridgeUpToDate = self.isBridgeInstalled && SystemDNSManager.isBridgeBinaryUpToDate()
            self.selectedProviderID = nil
            self.activeModeText = "Системный DNS (DHCP роутера)"
            self.statusMessage = "DoH-мост удалён, восстановлен системный DNS"
        }
    }

    public func checkAllProvidersHealth() async {
        guard !isCheckingAll else { return }
        isCheckingAll = true
        for p in providers {
            healthMap[p.id] = .checking
        }

        await withTaskGroup(of: (String, ProviderHealth).self) { group in
            for provider in providers {
                group.addTask {
                    let h = await LocalDoHProxy.shared.checkProviderHealth(provider)
                    return (provider.id, h)
                }
            }
            for await (id, health) in group {
                healthMap[id] = health
            }
        }
        isCheckingAll = false

        // Auto-failover if enabled and active provider is unhealthy
        if autoFailoverEnabled, let activeID = selectedProviderID {
            let currentHealth = healthMap[activeID] ?? .unknown
            if !currentHealth.isHealthy {
                selectBestHealthyProvider(reason: "Авто-переключение (текущий сервер недоступен)")
            }
        }
    }

    public func selectBestSmartProvider() {
        Task {
            statusMessage = "Тестируем все сервисы (DoH + доступность прокси)…"
            await checkAllProvidersHealth()
            selectBestHealthyProvider(reason: "Выбран самый быстрый рабочий сервер")
        }
    }

    private func selectBestHealthyProvider(reason: String) {
        let menuBarCandidates = providers.filter { $0.isEnabledInMenuBar }.compactMap { p -> (DNSProvider, Int)? in
            if case .healthy(let ms, _) = healthMap[p.id] {
                return (p, ms)
            }
            return nil
        }.sorted { $0.1 < $1.1 }

        let allCandidates = providers.compactMap { p -> (DNSProvider, Int)? in
            if case .healthy(let ms, _) = healthMap[p.id] {
                return (p, ms)
            }
            return nil
        }.sorted { $0.1 < $1.1 }

        let healthyCandidates = menuBarCandidates.isEmpty ? allCandidates : menuBarCandidates

        if let best = healthyCandidates.first {
            if selectedProviderID != best.0.id {
                selectProvider(best.0)
                statusMessage = "\(reason): \(best.0.name) (\(best.1) мс)"
            } else {
                statusMessage = "\(best.0.name) уже активен и работает отлично (\(best.1) мс)"
            }
        } else {
            statusMessage = "Ни один из сервисов сейчас не прошёл полную проверку"
        }
    }

    public func addCustomProvider(name: String, dohURL: String, bootstrapIP: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = dohURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanIP = bootstrapIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanURL.hasPrefix("https://"), let parsed = URL(string: cleanURL), let host = parsed.host else {
            statusMessage = "Укажите корректный https:// адрес DoH"
            return
        }
        if cleanIP.isEmpty && host.lowercased().contains("tunnelhunt.ru") {
            cleanIP = "135.106.164.115"
        }
        let newProvider = DNSProvider(
            id: "custom-\(UUID().uuidString.prefix(8))",
            name: cleanName,
            subtitle: "\(host) • Пользовательский DoH",
            dohURL: cleanURL,
            dotHost: host,
            bootstrapIPs: cleanIP.isEmpty ? [] : [cleanIP],
            plainDNSSupported: !cleanIP.isEmpty,
            websiteURL: "https://\(host)",
            isBuiltIn: false,
            isEnabledInMenuBar: true
        )
        providers.append(newProvider)
        saveAllProviders()
        Task {
            healthMap[newProvider.id] = .checking
            healthMap[newProvider.id] = await LocalDoHProxy.shared.checkProviderHealth(newProvider)
        }
    }

    public func removeProvider(_ provider: DNSProvider) {
        if selectedProviderID == provider.id {
            disableCustomDNS()
        }
        providers.removeAll { $0.id == provider.id }
        saveAllProviders()
    }

    public func toggleProviderInMenuBar(_ provider: DNSProvider) {
        guard let idx = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[idx].isEnabledInMenuBar.toggle()
        saveAllProviders()
    }

    public func restoreDefaultProviders() {
        var existingIDs = Set(providers.map { $0.id })
        for defaultP in DNSProvider.builtInProviders {
            if !existingIDs.contains(defaultP.id) {
                providers.append(defaultP)
                existingIDs.insert(defaultP.id)
            }
        }
        saveAllProviders()
        Task {
            await checkAllProvidersHealth()
        }
    }

    public func addExcludedDomains(_ rawInput: String) {
        let parts = rawInput.components(separatedBy: CharacterSet(charactersIn: ",;\n\t "))
        var addedCount = 0
        for part in parts {
            guard let normalized = SystemDNSManager.normalizeDomainRule(part) else { continue }
            if !excludedDomains.contains(normalized) {
                excludedDomains.append(normalized)
                addedCount += 1
            }
        }
        guard addedCount > 0 else { return }
        saveExcludedDomains()
        LocalDoHProxy.shared.setExcludedDomains(excludedDomains)
        SystemDNSManager.flushDNSCache()
        statusMessage = "Добавлено в исключения: \(addedCount) дом."
    }

    public func removeExcludedDomain(_ domain: String) {
        excludedDomains.removeAll { $0 == domain }
        saveExcludedDomains()
        LocalDoHProxy.shared.setExcludedDomains(excludedDomains)
        SystemDNSManager.flushDNSCache()
    }

    public func clearExcludedDomains() {
        excludedDomains.removeAll()
        saveExcludedDomains()
        LocalDoHProxy.shared.setExcludedDomains(excludedDomains)
        SystemDNSManager.flushDNSCache()
    }

    public func handleAppTermination() {
        if resetDNSOnQuit && selectedProviderID != nil {
            SystemDNSManager.resetToSystemDefault()
        }
    }

    private func loadProviders() {
        if let data = UserDefaults.standard.data(forKey: allProvidersKey),
           let saved = try? JSONDecoder().decode([DNSProvider].self, from: data),
           !saved.isEmpty {
            // Keep user custom providers, but synchronize built-in providers with latest working endpoints/bootstrap IPs
            var updatedList: [DNSProvider] = []
            for item in saved {
                if let builtIn = DNSProvider.builtInProviders.first(where: { $0.id == item.id }) {
                    var fresh = builtIn
                    fresh.isEnabledInMenuBar = item.isEnabledInMenuBar
                    updatedList.append(fresh)
                } else {
                    var custom = item
                    // Auto-fix tunnelhunt IP if empty
                    if custom.bootstrapIPs.isEmpty && custom.dohHost.lowercased().contains("tunnelhunt.ru") {
                        custom.bootstrapIPs = ["135.106.164.115"]
                    }
                    updatedList.append(custom)
                }
            }
            // Append any newly added built-ins (e.g. Comss.one)
            for builtIn in DNSProvider.builtInProviders {
                if !updatedList.contains(where: { $0.id == builtIn.id }) {
                    updatedList.append(builtIn)
                }
            }
            self.providers = updatedList
            saveAllProviders()
            return
        }
        var list = DNSProvider.builtInProviders
        if let data = UserDefaults.standard.data(forKey: customProvidersKey),
           let custom = try? JSONDecoder().decode([DNSProvider].self, from: data) {
            list.append(contentsOf: custom)
        }
        self.providers = list
        saveAllProviders()
    }

    private func saveAllProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: allProvidersKey)
        }
    }

    private func loadExcludedDomains() {
        if let saved = UserDefaults.standard.stringArray(forKey: excludedDomainsKey) {
            self.excludedDomains = saved.compactMap { SystemDNSManager.normalizeDomainRule($0) }
        }
        LocalDoHProxy.shared.setExcludedDomains(self.excludedDomains)
    }

    private func saveExcludedDomains() {
        UserDefaults.standard.set(excludedDomains, forKey: excludedDomainsKey)
    }

    public nonisolated func handleQueryResolution(isSuccess: Bool, serverName: String) {
        let failCount = failureTracker.record(isSuccess: isSuccess)
        if failCount >= 3 {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.consecutiveFailures = failCount
                if self.autoFailoverEnabled {
                    self.selectBestHealthyProvider(reason: "Авто-переключение (сервер \(serverName) не отвечает)")
                } else if let active = self.activeProvider {
                    self.statusMessage = "⚠️ Ошибка DoH (\(active.name)): проверьте токен или смените сервер"
                }
            }
        }
    }
}
