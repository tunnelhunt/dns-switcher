import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showAddSheet = false
    @State private var newName = ""
    @State private var newDoHURL = ""
    @State private var newBootstrapIP = ""

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
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

                    Text("Используется при сбое DoH или закрытом приложении • Активен: \(viewModel.resolvedFallbackIP):53")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                ForEach(viewModel.providers) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(provider.name)
                                    .fontWeight(.medium)
                                if !provider.isBuiltIn {
                                    Text("Пользовательский")
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.15))
                                        .cornerRadius(4)
                                }
                            }
                            Text(provider.dohURL)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if !provider.isBuiltIn {
                            Button(role: .destructive) {
                                viewModel.removeCustomProvider(provider)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                if showAddSheet {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Название (например, Comss DNS)", text: $newName)
                            .textFieldStyle(.roundedBorder)
                        TextField("DoH URL (https://.../dns-query)", text: $newDoHURL)
                            .textFieldStyle(.roundedBorder)
                        TextField("Bootstrap IPv4 (необязательно)", text: $newBootstrapIP)
                            .textFieldStyle(.roundedBorder)
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
                Text("Серверы DNS-over-HTTPS")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
    }
}
