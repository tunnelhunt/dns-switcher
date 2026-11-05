import SwiftUI
import AppKit

public struct MenuBarView: View {
    @ObservedObject var viewModel: AppViewModel
    var onOpenSettings: () -> Void

    @State private var hoveredProviderID: String?
    @State private var hoveredFooterItem: String?

    public init(viewModel: AppViewModel, onOpenSettings: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onOpenSettings = onOpenSettings
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

            if viewModel.isBridgeInstalled && !viewModel.isBridgeUpToDate {
                bridgeUpdateBanner
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
        .background(
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
        )
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: - Control Center Header

    private var headerSection: some View {
        let isActive = (viewModel.selectedProviderID != nil)
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isActive ? Color.blue : Color.primary.opacity(0.1))
                    .frame(width: 28, height: 28)
                Image(nsImage: StatusIcon.image(isActive: isActive, size: 15))
                    .renderingMode(.template)
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
                .toggleStyle(ControlCenterToggleStyle())
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    // MARK: - Servers List (Wi-Fi Control Center Style)

    private var serversSection: some View {
        let visibleProviders = viewModel.providers.filter { $0.isEnabledInMenuBar }
        return VStack(alignment: .leading, spacing: 2) {
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

            if visibleProviders.isEmpty {
                Text("Серверы скрыты из меню трея.\nВключите их в Настройках.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                ForEach(visibleProviders) { provider in
                    serverRow(provider)
                }
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
                            .foregroundColor(.blue)
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

    private var bridgeUpdateBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 1) {
                Text("Обновление DoH-моста")
                    .font(.system(size: 11, weight: .semibold))
                Text("Требуется обновить службу")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Обновить") {
                viewModel.installBridgeManually()
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(6)
    }

    // MARK: - Footer Menu Items

    private var footerMenuSection: some View {
        VStack(spacing: 1) {
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

public struct VisualEffectView: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode

    public init(material: NSVisualEffectView.Material = .popover, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

public struct ControlCenterToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                configuration.isOn.toggle()
            }
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Color.blue : Color.primary.opacity(0.18))
                    .frame(width: 34, height: 20)

                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .padding(2)
                    .shadow(color: Color.black.opacity(0.20), radius: 1, x: 0, y: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
