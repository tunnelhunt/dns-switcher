import SwiftUI
import AppKit

public struct MenuBarView: View {
    @ObservedObject var viewModel: AppViewModel
    var onOpenSettings: () -> Void
    var onOpenHistory: () -> Void

    @State private var hoveredProviderID: String?
    @State private var hoveredFooterItem: String?

    public init(viewModel: AppViewModel, onOpenSettings: @escaping () -> Void = {}, onOpenHistory: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onOpenSettings = onOpenSettings
        self.onOpenHistory = onOpenHistory
    }

    private var isDNSEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.selectedProviderID != nil },
            set: { newValue in
                if newValue {
                    viewModel.enableLastOrDefaultProvider()
                } else {
                    viewModel.disableCustomDNS()
                }
            }
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerSection

            if viewModel.hasConflictingProfile {
                conflictingProfileBanner
            }

            Divider()
                .padding(.horizontal, 2)

            serversSection

            Divider()
                .padding(.horizontal, 2)

            footerMenuSection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(width: 288)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Control Center Header

    private var headerSection: some View {
        let isActive = (viewModel.selectedProviderID != nil)
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isActive ? Color.accentColor : Color.primary.opacity(0.1))
                    .frame(width: 28, height: 28)
                Image(systemName: "network")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isActive ? .white : .secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("AI DNS")
                    .font(.system(size: 13, weight: .semibold))
                Text(viewModel.shortStatusText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: isDNSEnabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    // MARK: - Servers List (Wi-Fi Control Center Style)

    private var serversSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Серверы")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    viewModel.selectBestSmartProvider()
                } label: {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.plain)
                .help("Выбрать самый быстрый сервер")
                .disabled(viewModel.isCheckingAll)

                Button {
                    Task { await viewModel.checkAllProvidersHealth() }
                } label: {
                    Group {
                        if viewModel.isCheckingAll {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(width: 20, height: 18)
                }
                .buttonStyle(.plain)
                .help("Обновить пинг")
                .disabled(viewModel.isCheckingAll)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 2)

            ForEach(viewModel.providers) { provider in
                serverRow(provider)
            }
        }
    }

    private func serverRow(_ provider: DNSProvider) -> some View {
        let isSelected = (viewModel.selectedProviderID == provider.id)
        let isHovered = (hoveredProviderID == provider.id)
        let health = viewModel.healthMap[provider.id] ?? .unknown

        return Button {
            viewModel.selectProvider(provider)
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.accentColor)
                    }
                }
                .frame(width: 14)

                Text(provider.name)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                compactHealthIndicator(health)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isHovered
                            ? Color.primary.opacity(0.08)
                            : (isSelected ? Color.primary.opacity(0.04) : Color.clear)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredProviderID = hovering ? provider.id : nil
        }
    }

    @ViewBuilder
    private func compactHealthIndicator(_ health: ProviderHealth) -> some View {
        switch health {
        case .unknown:
            EmptyView()
        case .checking:
            ProgressView()
                .controlSize(.mini)
        case .healthy(let ms, _):
            HStack(spacing: 5) {
                Text("\(ms) мс")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            }
        case .degraded(let ms, let reason):
            HStack(spacing: 5) {
                Text("\(ms) мс")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
            }
            .help(reason)
        case .unreachable(let reason):
            HStack(spacing: 5) {
                Text("недоступен")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
            }
            .help(reason)
        }
    }

    // MARK: - Conflicting Profile Warning

    private var conflictingProfileBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 12))
            Text("В системе активен старый профиль DNS")
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
            Button("Открыть…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.configurationprofiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.link)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(6)
    }

    // MARK: - Footer Menu Items

    private var footerMenuSection: some View {
        VStack(spacing: 1) {
            footerMenuButton(id: "history", title: "История запросов…", shortcut: "⌘H") {
                onOpenHistory()
            }

            footerMenuButton(id: "settings", title: "Настройки AI DNS…", shortcut: "⌘,") {
                onOpenSettings()
            }

            footerMenuButton(id: "quit", title: "Выход", shortcut: "⌘Q") {
                viewModel.handleAppTermination()
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func footerMenuButton(id: String, title: String, shortcut: String, action: @escaping () -> Void) -> some View {
        let isHovered = (hoveredFooterItem == id)
        return Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                Spacer()
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredFooterItem = hovering ? id : nil
        }
    }
}
