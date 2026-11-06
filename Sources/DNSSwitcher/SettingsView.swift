import SwiftUI
import AppKit

public enum SettingsTab: String, CaseIterable, Identifiable {
    case servers = "Серверы"
    case bridge = "DoH-мост"
    case exceptions = "Исключения"
    case general = "Основные"

    public var id: String { rawValue }

    var icon: String {
        switch self {
        case .servers: return "server.rack"
        case .bridge: return "network"
        case .exceptions: return "arrow.triangle.branch"
        case .general: return "gearshape"
        }
    }
}

public struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    var onOpenHistory: (() -> Void)? = nil

    @State private var selectedTab: SettingsTab = .servers
    @State private var showAddSheet = false
    @State private var newName = ""
    @State private var newDoHURL = ""
    @State private var newBootstrapIP = ""
    @State private var newExcludedDomain = ""

    public init(viewModel: AppViewModel, onOpenHistory: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.onOpenHistory = onOpenHistory
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Segmented Tab Picker Header
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Active Tab Content
            Group {
                switch selectedTab {
                case .servers:
                    serversTab
                case .bridge:
                    bridgeTab
                case .exceptions:
                    exceptionsTab
                case .general:
                    generalTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 550, height: 530)
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: - Tab 1: DoH Servers

    private var serversTab: some View {
        Form {
            Section {
                let enabledCount = viewModel.providers.filter { $0.isEnabledInMenuBar }.count
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Серверы DNS-over-HTTPS")
                            .font(.headline)
                        Text("Всего: \(viewModel.providers.count) • В меню трея: \(enabledCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if !DNSProvider.builtInProviders.allSatisfy({ bp in viewModel.providers.contains(where: { $0.id == bp.id }) }) {
                        Button("Восстановить встроенные") {
                            viewModel.restoreDefaultProviders()
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showAddSheet.toggle()
                        }
                    } label: {
                        Label(showAddSheet ? "Скрыть" : "Добавить…", systemImage: showAddSheet ? "chevron.up" : "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }

            if showAddSheet {
                Section("Новый DoH-сервер") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Название (например, Quad9 DNS)", text: $newName)
                            .textFieldStyle(.roundedBorder)
                        TextField("DoH URL (https://.../dns-query)", text: $newDoHURL)
                            .textFieldStyle(.roundedBorder)
                        TextField("Bootstrap IPv4 (необязательно, например 9.9.9.9)", text: $newBootstrapIP)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Spacer()
                            Button("Отмена") {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showAddSheet = false
                                }
                            }
                            .controlSize(.small)

                            Button("Добавить сервер") {
                                viewModel.addCustomProvider(name: newName, dohURL: newDoHURL, bootstrapIP: newBootstrapIP)
                                newName = ""
                                newDoHURL = ""
                                newBootstrapIP = ""
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showAddSheet = false
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || !newDoHURL.hasPrefix("https://"))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                ForEach(viewModel.providers) { provider in
                    serverRow(provider)
                }
            } header: {
                Text("Список серверов")
            } footer: {
                Text("Тумблер слева включает или выключает сервер в списке быстрого переключения в строке меню. Значок корзины удаляет сервер.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func serverRow(_ provider: DNSProvider) -> some View {
        let health = viewModel.healthMap[provider.id] ?? .unknown

        return HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { provider.isEnabledInMenuBar },
                set: { _ in viewModel.toggleProviderInMenuBar(provider) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(.blue)
            .help(provider.isEnabledInMenuBar ? "Отображается в трее" : "Скрыт из меню трея")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(provider.name)
                        .fontWeight(.medium)

                    if provider.isBuiltIn {
                        Text("Встроенный")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.12))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    } else {
                        Text("Пользовательский")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.12))
                            .foregroundColor(.purple)
                            .cornerRadius(4)
                    }

                    if !provider.isEnabledInMenuBar {
                        Text("Скрыт")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                Text(provider.dohURL)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            serverHealthBadge(health)

            Button(role: .destructive) {
                viewModel.removeProvider(provider)
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help("Удалить DNS-сервер")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func serverHealthBadge(_ health: ProviderHealth) -> some View {
        switch health {
        case .unknown:
            EmptyView()
        case .checking:
            ProgressView()
                .controlSize(.mini)
        case .healthy(let ms, _):
            HStack(spacing: 4) {
                Text("\(ms) мс")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            }
        case .degraded(let ms, let reason):
            HStack(spacing: 4) {
                Text("\(ms) мс")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
            }
            .help(reason)
        case .unreachable(let reason):
            HStack(spacing: 4) {
                Text("сбой")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
            }
            .help(reason)
        }
    }

    // MARK: - Tab 2: DoH Bridge & Network

    private var bridgeTab: some View {
        Form {
            Section("Системный DoH-мост (127.0.0.1:53)") {
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(!viewModel.isBridgeInstalled ? Color.orange : (!viewModel.isBridgeUpToDate ? Color.orange : Color.green))
                        .frame(width: 10, height: 10)
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(!viewModel.isBridgeInstalled
                             ? "Служба моста не установлена"
                             : (!viewModel.isBridgeUpToDate ? "Служба установлена (требуется обновление)" : "Служба моста установлена и активна"))
                            .fontWeight(.medium)

                        Text("Локальный демон перехватывает DNS-запросы системы на 127.0.0.1:53 и отправляет их в зашифрованный DoH без необходимости устанавливать конфигурационные профили.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    if !viewModel.isBridgeInstalled {
                        Button("Установить…") {
                            viewModel.installBridgeManually()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else if !viewModel.isBridgeUpToDate {
                        Button("Обновить…") {
                            viewModel.installBridgeManually()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button("Удалить") {
                            viewModel.uninstallBridgeManually()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }

            Section("Резервный DNS (Фоллбэк)") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Использовать при сбое DoH:", selection: $viewModel.fallbackOption) {
                        ForEach(FallbackDNSOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }

                    if viewModel.fallbackOption == .custom {
                        HStack(spacing: 8) {
                            TextField("IPv4-адрес (например, 9.9.9.9)", text: $viewModel.customFallbackIP)
                                .textFieldStyle(.roundedBorder)
                            if SystemDNSManager.isValidNonLoopbackIPv4(viewModel.customFallbackIP) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .help("Корректный IPv4-адрес")
                            } else if !viewModel.customFallbackIP.trimmingCharacters(in: .whitespaces).isEmpty {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .help("Введите корректный IPv4-адрес (не 127.x.x.x)")
                            }
                        }
                    }

                    if viewModel.fallbackOption == .disabled {
                        HStack(spacing: 6) {
                            Image(systemName: "shield.slash")
                                .foregroundColor(.orange)
                            Text("Фоллбэк отключён: при недоступности DoH запросы не утекают на открытые DNS • Режим повышенной приватности")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    } else {
                        Text("Используется при временном сбое DoH или когда приложение выключено • Активен: \(viewModel.resolvedFallbackIP):53")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section("Диагностика и Журнал") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Системный кэш DNS")
                            .fontWeight(.medium)
                        if viewModel.resolvedCount > 0 {
                            Text("Обработано запросов прокси: \(viewModel.resolvedCount)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Сбросить кэш резолвера macOS (dscacheutil)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button("Очистить кэш") {
                        SystemDNSManager.flushDNSCache()
                        LocalDoHProxy.shared.clearCache()
                        viewModel.statusMessage = "Кэш DNS успешно очищен"
                    }
                    .controlSize(.small)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Журнал DNS-запросов")
                            .fontWeight(.medium)
                        Text("Записей в сессии: \(viewModel.resolutionHistory.count) (кэш, DoH, задержки)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Показать историю…") {
                        onOpenHistory?()
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Tab 3: Excluded Domains (VPN / Direct)

    private var exceptionsTab: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundColor(.blue)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Обход DoH для локальных сетей и VPN")
                                .font(.headline)
                            Text("Запросы к этим доменам направляются напрямую через системный/VPN DNS. Это позволяет внутренним ресурсам компании работать стабильно.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)

                    HStack(spacing: 8) {
                        TextField("Домен или список через запятую (напр. corp.local, company.ru)", text: $newExcludedDomain)
                            .textFieldStyle(.roundedBorder)

                        Button("Добавить") {
                            addExcludedDomainAction()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(SystemDNSManager.normalizeDomainRule(newExcludedDomain) == nil)
                    }
                    .padding(.top, 4)
                }
            }

            Section {
                if viewModel.excludedDomains.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text("Список исключений пуст")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Все запросы безопасно шифруются через выбранный DoH-сервер. Добавьте локальные домены, если используете корпоративный VPN.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    ForEach(viewModel.excludedDomains, id: \.self) { domain in
                        HStack {
                            HStack(spacing: 6) {
                                Text(domain)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                Text("+ *.\(domain)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.12))
                                    .cornerRadius(4)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                viewModel.removeExcludedDomain(domain)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Удалить домен из исключений")
                        }
                        .padding(.vertical, 1)
                    }
                }
            } header: {
                HStack {
                    Text("Активные исключения (\(viewModel.excludedDomains.count))")
                    Spacer()
                    if viewModel.excludedDomains.count > 1 {
                        Button("Очистить все") {
                            viewModel.clearExcludedDomains()
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Tab 4: General & Automation

    private var generalTab: some View {
        Form {
            Section("Автоматизация") {
                Toggle(isOn: $viewModel.autoFailoverEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Умный фоллбэк (авто-смена сервера)")
                            .fontWeight(.medium)
                        Text("Автоматически переключаться на самый быстрый рабочий сервер при недоступности или сбое текущего.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Toggle(isOn: $viewModel.alwaysShowInDock) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Отображать значок в Dock")
                            .fontWeight(.medium)
                        Text("Показывать значок приложения в Dock для быстрого доступа, даже если строка меню переполнена.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Toggle(isOn: $viewModel.resetDNSOnQuit) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Возвращать системный DNS при выходе")
                            .fontWeight(.medium)
                        Text("При закрытии приложения сбрасывать настройки DNS к стандартным (DHCP роутера).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("Горячие клавиши") {
                shortcutRow(title: "Открыть настройки", shortcut: "⌘ ,")
                shortcutRow(title: "Закрыть активное окно", shortcut: "⌘ W")
                shortcutRow(title: "Завершить работу", shortcut: "⌘ Q")
            }

            Section("О приложении") {
                HStack(spacing: 12) {
                    Image(nsImage: StatusIcon.appIconImage(size: 40))
                        .resizable()
                        .frame(width: 40, height: 40)
                        .cornerRadius(8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI DNS Switcher")
                            .fontWeight(.semibold)
                        Text("Версия 1.7.1 • macOS")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Прокси 127.0.0.1:53")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text(viewModel.activeModeText)
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(title: String, shortcut: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(shortcut)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
        }
    }

    private func addExcludedDomainAction() {
        let trimmed = newExcludedDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.addExcludedDomains(trimmed)
        newExcludedDomain = ""
    }
}
