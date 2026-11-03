import SwiftUI
import AppKit

public struct HistoryView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var searchText: String = ""
    @State private var selectedFilter: HistoryFilter = .all

    public enum HistoryFilter: String, CaseIterable, Identifiable {
        case all = "Все"
        case doh = "DoH"
        case cache = "Кэш"
        case stale = "Stale-кэш"
        case excluded = "Исключения"
        case fallback = "Фоллбэк"
        case error = "Ошибки"

        public var id: String { rawValue }

        func matches(_ record: DNSResolutionRecord) -> Bool {
            switch self {
            case .all:
                return true
            case .doh:
                return record.source == .doh
            case .cache:
                return record.source == .cache
            case .stale:
                return record.source == .staleCache
            case .excluded:
                return record.source == .excluded
            case .fallback:
                return record.source == .fallback
            case .error:
                return record.source == .error || !record.isSuccess
            }
        }
    }

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    private var filteredRecords: [DNSResolutionRecord] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return viewModel.resolutionHistory.filter { record in
            if !selectedFilter.matches(record) {
                return false
            }
            if !trimmed.isEmpty {
                let matchesDomain = record.domain.lowercased().contains(trimmed)
                let matchesIP = record.resolvedIPs.contains { $0.contains(trimmed) }
                let matchesServer = record.serverName.lowercased().contains(trimmed)
                return matchesDomain || matchesIP || matchesServer
            }
            return true
        }
    }

    private var stats: (doh: Int, cache: Int, stale: Int, failed: Int) {
        var doh = 0, cache = 0, stale = 0, failed = 0
        for r in viewModel.resolutionHistory {
            switch r.source {
            case .doh: doh += 1
            case .cache: cache += 1
            case .staleCache: stale += 1
            case .error: failed += 1
            default: break
            }
        }
        return (doh, cache, stale, failed)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Toolbar & Stats
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("История DNS-запросов")
                            .font(.headline)
                        Text("Мониторинг всех резолвов в реальном времени с поддержкой Serve-Stale кэша")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button {
                        copyHistoryToClipboard()
                    } label: {
                        Label("Копировать", systemImage: "doc.on.doc")
                    }
                    .disabled(viewModel.resolutionHistory.isEmpty)

                    Button(role: .destructive) {
                        viewModel.clearHistory()
                    } label: {
                        Label("Очистить", systemImage: "trash")
                    }
                    .disabled(viewModel.resolutionHistory.isEmpty)
                }

                HStack(spacing: 8) {
                    statPill(title: "Всего", count: viewModel.resolutionHistory.count, color: .primary)
                    statPill(title: "DoH", count: stats.doh, color: .green)
                    statPill(title: "Кэш", count: stats.cache, color: .blue)
                    if stats.stale > 0 {
                        statPill(title: "Stale-кэш", count: stats.stale, color: .orange)
                    }
                    if stats.failed > 0 {
                        statPill(title: "Ошибки", count: stats.failed, color: .red)
                    }
                    Spacer()
                }

                // Filter & Search
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Фильтр по домену или IP…", text: $searchText)
                            .textFieldStyle(.plain)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)

                    Picker("Фильтр", selection: $selectedFilter) {
                        ForEach(HistoryFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Records List
            if filteredRecords.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.6))
                    if viewModel.resolutionHistory.isEmpty {
                        Text("История запросов пока пуста")
                            .font(.system(size: 14, weight: .medium))
                        Text("Запросы, отправленные через 127.0.0.1:53, будут отображаться здесь")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("По заданному фильтру ничего не найдено")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredRecords) { record in
                        recordRow(record)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(minWidth: 700, idealWidth: 720, minHeight: 440, idealHeight: 480)
    }

    private func statPill(title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.08))
        .cornerRadius(4)
    }

    private func recordRow(_ record: DNSResolutionRecord) -> some View {
        HStack(spacing: 8) {
            // Timestamp
            Text(formatTime(record.timestamp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)

            // Source Badge
            sourceBadge(record.source)
                .frame(width: 82, alignment: .leading)

            // QType Badge (e.g. A, AAAA, HTTPS)
            Text(record.qtype)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(3)
                .frame(width: 44, alignment: .center)

            // Domain
            Text(record.domain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Resolved IPs or Server
            if !record.resolvedIPs.isEmpty {
                Text(record.resolvedIPs.joined(separator: ", "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(record.serverName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            // Latency
            Text(record.source == .cache ? "<1 мс" : "\(record.latencyMs) мс")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(record.isSuccess ? .secondary : .red)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func sourceBadge(_ source: ResolutionSource) -> some View {
        let (label, bg, fg): (String, Color, Color) = {
            switch source {
            case .doh:
                return ("DoH", Color.green.opacity(0.15), Color.green)
            case .cache:
                return ("Кэш", Color.blue.opacity(0.15), Color.blue)
            case .staleCache:
                return ("Stale-кэш", Color.orange.opacity(0.15), Color.orange)
            case .excluded:
                return ("Исключение", Color.purple.opacity(0.15), Color.purple)
            case .fallback:
                return ("Фоллбэк", Color.yellow.opacity(0.2), Color.orange)
            case .error:
                return ("Ошибка", Color.red.opacity(0.15), Color.red)
            }
        }()

        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg)
            .cornerRadius(4)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func copyHistoryToClipboard() {
        let lines = viewModel.resolutionHistory.map { r in
            let time = formatTime(r.timestamp)
            let ips = r.resolvedIPs.isEmpty ? r.serverName : r.resolvedIPs.joined(separator: ", ")
            return "\(time)\t\(r.source.rawValue)\t\(r.qtype)\t\(r.domain)\t\(ips)\t\(r.latencyMs)ms"
        }
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
