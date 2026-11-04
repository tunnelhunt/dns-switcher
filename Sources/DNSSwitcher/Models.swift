import Foundation

public enum FallbackDNSOption: String, CaseIterable, Identifiable, Codable {
    case disabled = "disabled"
    case system = "system"
    case yandex = "yandex"
    case cloudflare = "cloudflare"
    case google = "google"
    case custom = "custom"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .disabled:
            return "Отключить (без фоллбэка)"
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
        case .disabled:
            return nil
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

public enum ResolutionSource: String, Codable, CaseIterable {
    case doh = "DoH"
    case cache = "Кэш"
    case staleCache = "Кэш (stale)"
    case excluded = "Исключение"
    case fallback = "Фоллбэк"
    case error = "Ошибка"

    public var title: String {
        switch self {
        case .doh: return "DoH"
        case .cache: return "Кэш"
        case .staleCache: return "Кэш (резервный)"
        case .excluded: return "Исключение"
        case .fallback: return "Фоллбэк"
        case .error: return "Ошибка"
        }
    }
}

public struct DNSResolutionRecord: Identifiable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let domain: String
    public let qtype: String
    public let source: ResolutionSource
    public let serverName: String
    public let latencyMs: Int
    public let resolvedIPs: [String]
    public let isSuccess: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        domain: String,
        qtype: String,
        source: ResolutionSource,
        serverName: String,
        latencyMs: Int,
        resolvedIPs: [String],
        isSuccess: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.domain = domain
        self.qtype = qtype
        self.source = source
        self.serverName = serverName
        self.latencyMs = latencyMs
        self.resolvedIPs = resolvedIPs
        self.isSuccess = isSuccess
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
    public var isEnabledInMenuBar: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, subtitle, dohURL, dotHost, bootstrapIPs, plainDNSSupported, websiteURL, isBuiltIn, isEnabledInMenuBar
    }

    public init(
        id: String,
        name: String,
        subtitle: String,
        dohURL: String,
        dotHost: String,
        bootstrapIPs: [String],
        plainDNSSupported: Bool,
        websiteURL: String,
        isBuiltIn: Bool = false,
        isEnabledInMenuBar: Bool = true
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.dohURL = dohURL
        self.dotHost = dotHost
        self.bootstrapIPs = bootstrapIPs
        self.plainDNSSupported = plainDNSSupported
        self.websiteURL = websiteURL
        self.isBuiltIn = isBuiltIn
        self.isEnabledInMenuBar = isEnabledInMenuBar
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.subtitle = try container.decode(String.self, forKey: .subtitle)
        self.dohURL = try container.decode(String.self, forKey: .dohURL)
        self.dotHost = try container.decode(String.self, forKey: .dotHost)
        self.bootstrapIPs = try container.decode([String].self, forKey: .bootstrapIPs)
        self.plainDNSSupported = try container.decode(Bool.self, forKey: .plainDNSSupported)
        self.websiteURL = try container.decode(String.self, forKey: .websiteURL)
        self.isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        self.isEnabledInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .isEnabledInMenuBar) ?? true
    }

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
            isBuiltIn: true,
            isEnabledInMenuBar: true
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
            isBuiltIn: true,
            isEnabledInMenuBar: true
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
            isBuiltIn: true,
            isEnabledInMenuBar: true
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
