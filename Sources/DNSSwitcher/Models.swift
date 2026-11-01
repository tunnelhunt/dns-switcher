import Foundation

public enum FallbackDNSOption: String, CaseIterable, Identifiable, Codable {
    case system = "system"
    case yandex = "yandex"
    case cloudflare = "cloudflare"
    case google = "google"
    case custom = "custom"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system:
            return "Системный (DHCP роутера)"
        case .yandex:
            return "Яндекс.DNS (77.88.8.8)"
        case .cloudflare:
            return "Cloudflare (1.1.1.1)"
        case .google:
            return "Google (8.8.8.8)"
        case .custom:
            return "Указать свой IPv4…"
        }
    }

    public var staticIP: String? {
        switch self {
        case .system:
            return nil
        case .yandex:
            return "77.88.8.8"
        case .cloudflare:
            return "1.1.1.1"
        case .google:
            return "8.8.8.8"
        case .custom:
            return nil
        }
    }
}

public struct DNSProvider: Identifiable, Codable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var subtitle: String
    public var dohURL: String
    public var dotHost: String
    public var bootstrapIPs: [String]
    public var plainDNSSupported: Bool
    public var websiteURL: String
    public var isBuiltIn: Bool

    public var dohHost: String {
        URL(string: dohURL)?.host ?? dotHost
    }

    public static let builtInProviders: [DNSProvider] = [
        DNSProvider(
            id: "magicdns",
            name: "MagicDNS",
            subtitle: "magicdns.ru • DoH + IPv4",
            dohURL: "https://dns.magicdns.ru/dns-query",
            dotHost: "dns.magicdns.ru",
            bootstrapIPs: ["109.120.132.43", "94.249.177.102", "138.124.59.86"],
            plainDNSSupported: true,
            websiteURL: "https://magicdns.ru/",
            isBuiltIn: true
        ),
        DNSProvider(
            id: "dns-ai",
            name: "DNS-AI",
            subtitle: "dns-ai.ru • Только DoH / DoT",
            dohURL: "https://dns.dns-ai.ru/dns-query",
            dotHost: "dns.dns-ai.ru",
            bootstrapIPs: ["194.87.196.13", "45.151.102.219"],
            plainDNSSupported: false,
            websiteURL: "https://dns-ai.ru/",
            isBuiltIn: true
        ),
        DNSProvider(
            id: "dagami",
            name: "Dagami DNS",
            subtitle: "dns.dagami.ru • DoH + IPv4",
            dohURL: "https://dns.dagami.ru/dns-query",
            dotHost: "dns.dagami.ru",
            bootstrapIPs: ["89.22.224.205"],
            plainDNSSupported: true,
            websiteURL: "https://dns.dagami.ru/",
            isBuiltIn: true
        )
    ]
}

public enum ProviderHealth: Equatable {
    case unknown
    case checking
    case healthy(latencyMs: Int, resolvedIP: String)
    case degraded(latencyMs: Int, reason: String)
    case unreachable(reason: String)

    public var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }

    public var latencyMs: Int? {
        switch self {
        case .healthy(let ms, _), .degraded(let ms, _):
            return ms
        default:
            return nil
        }
    }

    public var badgeText: String {
        switch self {
        case .unknown:
            return "Не проверен"
        case .checking:
            return "Проверка…"
        case .healthy(let ms, _):
            return "\(ms) мс"
        case .degraded(let ms, let reason):
            return "\(ms) мс • \(reason)"
        case .unreachable(let reason):
            return reason
        }
    }
}
