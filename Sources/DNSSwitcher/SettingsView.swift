import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    var onOpenHistory: (() -> Void)? = nil
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
        Form {
            Section("Автоматизация") {
                Toggle(isOn: $viewModel.autoFailoverEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Умный фоллбэк (авто-смена)")
                        Text("Автоматически переключаться на самый быстрый рабочий сервер при недоступности текущего")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Toggle(isOn: $viewModel.resetDNSOnQuit) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Возвращать системный DNS при выходе")
                        Text("При закрытии приложения сбрасывать настройки DNS к стандартным (DHCP роутера)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("Системный DoH-мост (127.0.0.1:53)") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.isBridgeInstalled ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(viewModel.isBridgeInstalled ? "Мост установлен и активен" : "Мост не установлен")
                                .fontWeight(.medium)
                        }
                        Text("Позволяет переключать зашифрованный DoH в 1 клик без установки .mobileconfig профилей")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if viewModel.isBridgeInstalled {
                        Button("Удалить") {
                            viewModel.uninstallBridgeManually()
                        }
                    } else {
                        Button("Установить…") {
                            viewModel.installBridgeManually()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Системный DNS-кэш")
                        if viewModel.resolvedCount > 0 {
                            Text("Обработано запросов через прокси: \(viewModel.resolvedCount)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Сбросить локальный кэш DNS-ответов macOS")
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
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("История DNS-запросов")
                        Text("Просмотр всех резолвов, задержек и ответов из кэша (записей: \(viewModel.resolutionHistory.count))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Показать историю…") {
                        onOpenHistory?()
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Резервный DNS (фоллбэк)", selection: $viewModel.fallbackOption) {
                        ForEach(FallbackDNSOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }

                    if viewModel.fallbackOption == .custom {
                        HStack(spacing: 8) {
                            TextField("IPv4-адрес (например, 9.9.9.9)", text: $viewModel.customFallbackIP)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
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
                        Text("Фоллбэк отключён: при сбое DoH запросы не утекают на открытые DNS-серверы • Строгий DoH")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else {
                        Text("Используется при сбое DoH или закрытом приложении • Активен: \(viewModel.resolvedFallbackIP):53")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Домен или список через запятую (напр. corp.local, company.ru)", text: $newExcludedDomain)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                        Button("Добавить") {
                            addExcludedDomainAction()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(SystemDNSManager.normalizeDomainRule(newExcludedDomain) == nil)
                    }

                    Text("Запросы к этим доменам (и их поддоменам) не идут через наш DoH, а отправляются напрямую через системный / VPN DNS. Это позволяет внутренним ресурсам работать через VPN.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if viewModel.excludedDomains.isEmpty {
                    Text("Список исключений пуст — все домены разрешаются через выбранный DoH-сервер")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                    }
                }
            } header: {
                HStack {
                    Text("Домены-исключения (Обход DoH / VPN)")
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

            Section {
                ForEach(viewModel.providers) { provider in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { provider.isEnabledInMenuBar },
                            set: { _ in viewModel.toggleProviderInMenuBar(provider) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(.blue)
                        .help(provider.isEnabledInMenuBar ? "Отображается в трее для быстрого выбора" : "Скрыт из меню трея")

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(provider.name)
                                    .fontWeight(.medium)
                                if provider.isBuiltIn {
                                    Text("Встроенный")
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.blue.opacity(0.12))
                                        .foregroundColor(.blue)
                                        .cornerRadius(4)
                                } else {
                                    Text("Пользовательский")
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.15))
                                        .cornerRadius(4)
                                }
                                if !provider.isEnabledInMenuBar {
                                    Text("Скрыт из трея")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            Text(provider.dohURL)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            viewModel.removeProvider(provider)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Удалить DNS-сервер")
                    }
                }

                if showAddSheet {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Название (например, Comss DNS)", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                        TextField("DoH URL (https://.../dns-query)", text: $newDoHURL)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                        TextField("Bootstrap IPv4 (необязательно)", text: $newBootstrapIP)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                        HStack {
                            Spacer()
                            Button("Отмена") {
                                showAddSheet = false
                            }
                            Button("Добавить") {
                                viewModel.addCustomProvider(name: newName, dohURL: newDoHURL, bootstrapIP: newBootstrapIP)
                                newName = ""
                                newDoHURL = ""
                                newBootstrapIP = ""
                                showAddSheet = false
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || !newDoHURL.hasPrefix("https://"))
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("Добавить DoH-сервер…", systemImage: "plus")
                    }
                }
            } header: {
                HStack {
                    Text("Серверы DNS-over-HTTPS")
                    Spacer()
                    if !DNSProvider.builtInProviders.allSatisfy({ bp in viewModel.providers.contains(where: { $0.id == bp.id }) }) {
                        Button("Восстановить встроенные") {
                            viewModel.restoreDefaultProviders()
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }
                }
            } footer: {
                Text("Тумблер слева включает или выключает сервер в списке быстрого выбора в трее. Значок корзины удаляет сервер.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 640)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func addExcludedDomainAction() {
        let trimmed = newExcludedDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.addExcludedDomains(trimmed)
        newExcludedDomain = ""
    }
}
