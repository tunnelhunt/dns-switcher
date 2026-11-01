import Foundation
import Darwin

public final class LocalDoHProxy: @unchecked Sendable {
    public static let shared = LocalDoHProxy()

    private let lock = NSLock()
    private var activeProvider: DNSProvider = DNSProvider.builtInProviders[0]
    private var allProviders: [DNSProvider] = DNSProvider.builtInProviders
    private var fallbackServer: String = Port53Bridge.defaultFallbackDNSServer
    private var excludedDomains: [String] = []
    private var cachedSystemServers: (servers: [String], expiresAt: Date)?
    private var cache: [String: (data: Data, expiresAt: Date)] = [:]
    private var isRunning = false

    private let urlSession: URLSession
    public var onQueryResolved: ((String, Int, Bool) -> Void)?

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 5.0
        config.httpMaximumConnectionsPerHost = 16
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.urlSession = URLSession(configuration: config)
    }

    public func configure(active: DNSProvider, all: [DNSProvider]) {
        lock.lock()
        let changed = (self.activeProvider.id != active.id || self.activeProvider.dohURL != active.dohURL)
        self.activeProvider = active
        self.allProviders = all
        if changed {
            self.cache.removeAll()
        }
        lock.unlock()
    }

    public func setFallbackServer(_ ip: String) {
        lock.lock()
        if SystemDNSManager.isValidNonLoopbackIPv4(ip) {
            self.fallbackServer = ip
            self.cachedSystemServers = nil
        }
        lock.unlock()
    }

    public func setExcludedDomains(_ domains: [String]) {
        let normalized = domains.compactMap { SystemDNSManager.normalizeDomainRule($0) }
        lock.lock()
        self.excludedDomains = normalized
        self.cachedSystemServers = nil
        self.cache.removeAll()
        lock.unlock()
    }

    /// Checks whether a queried domain matches any rule in `excludedDomains` (exact match or subdomain match).
    public static func isDomainExcluded(_ domain: String, excludedDomains: [String]) -> Bool {
        let cleanDomain = domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !cleanDomain.isEmpty else { return false }
        for rule in excludedDomains {
            guard !rule.isEmpty else { continue }
            if cleanDomain == rule || cleanDomain.hasSuffix("." + rule) {
                return true
            }
        }
        return false
    }

    public func clearCache() {
        lock.lock()
        cache.removeAll()
        cachedSystemServers = nil
        lock.unlock()
    }

    public func startIfNeeded() {
        lock.lock()
        if isRunning {
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.runUDPLoop()
        }
        thread.name = "com.dnsswitcher.localdoh.udp"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func runUDPLoop() {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var bindAddr = Port53Bridge.makeSockAddr(ip: Port53Bridge.listenIP, port: Port53Bridge.appProxyPort)
        let bindRes = withUnsafePointer(to: &bindAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            fputs("[LocalDoHProxy] Could not bind \(Port53Bridge.listenIP):\(Port53Bridge.appProxyPort) errno=\(errno)\n", stderr)
            close(sock)
            return
        }

        let sendLock = NSLock()
        var buf = [UInt8](repeating: 0, count: 4096)

        while true {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &clientAddr) { clientPtr in
                clientPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    recvfrom(sock, &buf, buf.count, 0, saPtr, &clientLen)
                }
            }
            guard n >= 12 else { continue }
            let queryData = Data(bytes: buf, count: n)
            let capturedClient = clientAddr

            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self,
                      let responseData = await self.resolveDNSQuery(queryData) else { return }
                Self.sendUDPReply(sock: sock, lock: sendLock, client: capturedClient, data: responseData)
            }
        }
    }

    private static func sendUDPReply(sock: Int32, lock: NSLock, client: sockaddr_in, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        var dest = client
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            withUnsafePointer(to: &dest) { destPtr in
                destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    _ = sendto(sock, base, data.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    public func resolveDNSQuery(_ query: Data) async -> Data? {
        let txID = DNSPacket.transactionID(of: query)
        let (provider, providers, fallbackHost, excluded) = getSnapshot()

        guard let question = DNSPacket.parseQuestion(from: query) else {
            return Port53Bridge.sendUDP(query: query, host: fallbackHost, port: 53, timeoutMs: 2000)
        }

        // 1. Bootstrap anti-recursion check: if the query is for any DoH server hostname itself
        if let matchedProvider = providers.first(where: { $0.dohHost.lowercased() == question.domain || $0.dotHost.lowercased() == question.domain }) {
            if !matchedProvider.bootstrapIPs.isEmpty,
               let synth = DNSPacket.synthesizeBootstrapResponse(for: query, ipv4List: matchedProvider.bootstrapIPs) {
                return synth
            }
            return Port53Bridge.sendUDP(query: query, host: fallbackHost, port: 53, timeoutMs: 2000)
        }

        // 1b. Excluded domains check: bypass DoH and route through system / VPN DNS
        if Self.isDomainExcluded(question.domain, excludedDomains: excluded) {
            let start = DispatchTime.now()
            if let bypassReply = resolveViaSystemDNS(query: query, fallbackHost: fallbackHost, providers: providers) {
                let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                onQueryResolved?(question.domain, max(1, elapsedMs), false)
                return DNSPacket.withTransactionID(txID, in: bypassReply)
            }
            return nil
        }

        // 2. Check in-memory TTL cache
        let cacheKey = "\(provider.id):\(question.domain):\(question.qtype)"
        if let cached = getCached(key: cacheKey) {
            onQueryResolved?(question.domain, 1, true)
            return DNSPacket.withTransactionID(txID, in: cached)
        }

        // 3. Query active DoH provider via RFC 8484 GET (?dns=...)
        let start = DispatchTime.now()
        if let dohReply = await performDoHRequest(query: query, dohURL: provider.dohURL) {
            let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            setCached(key: cacheKey, data: dohReply, ttlSeconds: 45)
            onQueryResolved?(question.domain, max(1, elapsedMs), false)
            return DNSPacket.withTransactionID(txID, in: dohReply)
        }

        // 4. Fallback if DoH request failed
        return Port53Bridge.sendUDP(query: query, host: fallbackHost, port: 53, timeoutMs: 2000)
    }

    private func resolveViaSystemDNS(query: Data, fallbackHost: String, providers: [DNSProvider]) -> Data? {
        let servers = getSystemAndVPNDNSServers(fallbackHost: fallbackHost, providers: providers)
        var firstFallbackReply: Data? = nil

        for server in servers {
            guard let reply = Port53Bridge.sendUDP(query: query, host: server, port: 53, timeoutMs: 1500),
                  reply.count >= 12 else {
                continue
            }
            let rcode = reply[3] & 0x0F
            if rcode == 0 {
                return reply
            }
            if firstFallbackReply == nil {
                firstFallbackReply = reply
            }
        }
        return firstFallbackReply
    }

    private func getSystemAndVPNDNSServers(fallbackHost: String, providers: [DNSProvider]) -> [String] {
        lock.lock()
        if let cached = cachedSystemServers, cached.expiresAt > Date() {
            lock.unlock()
            return cached.servers
        }
        lock.unlock()

        let bootstrapIPs = Set(providers.flatMap { $0.bootstrapIPs })
        let detected = SystemDNSManager.detectSystemAndVPNDNSServers(
            fallbackIP: fallbackHost,
            ignoringBootstrapIPs: bootstrapIPs
        )

        lock.lock()
        cachedSystemServers = (detected, Date().addingTimeInterval(3.0))
        lock.unlock()
        return detected
    }

    public func performDoHRequest(query: Data, dohURL: String) async -> Data? {
        let b64 = DNSPacket.base64URLEncode(query)
        let separator = dohURL.contains("?") ? "&" : "?"
        guard let url = URL(string: "\(dohURL)\(separator)dns=\(b64)") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResp = response as? HTTPURLResponse,
                  httpResp.statusCode == 200,
                  data.count >= 12 else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    /// Deep health check: resolves `chatgpt.com` via the provider's DoH endpoint AND verifies TCP port 443 reachability of the returned IP.
    public func checkProviderHealth(_ provider: DNSProvider, testDomain: String = "chatgpt.com") async -> ProviderHealth {
        let query = DNSPacket.buildAQuery(domain: testDomain, txID: 0x1234)
        let start = DispatchTime.now()
        guard let responseData = await performDoHRequest(query: query, dohURL: provider.dohURL) else {
            return .unreachable(reason: "DoH недоступен")
        }
        let dohMs = max(1, Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000))
        let ips = DNSPacket.extractARecords(from: responseData)
        guard let firstIP = ips.first else {
            return .degraded(latencyMs: dohMs, reason: "Пустой ответ DNS")
        }

        // Verify that the returned smart-proxy IP accepts TCP connections on port 443
        let tcpReachable = await Task.detached(priority: .utility) {
            Self.checkTCPPort443(ip: firstIP, timeoutMs: 1800)
        }.value

        if tcpReachable {
            return .healthy(latencyMs: dohMs, resolvedIP: firstIP)
        } else {
            return .degraded(latencyMs: dohMs, reason: "Прокси \(firstIP):443 не отвечает")
        }
    }

    private static func checkTCPPort443(ip: String, timeoutMs: Int32) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        var addr = Port53Bridge.makeSockAddr(ip: ip, port: 443)
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if res == 0 { return true }
        if errno == EINPROGRESS {
            var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            let pr = poll(&pfd, 1, timeoutMs)
            if pr > 0 {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len)
                return err == 0
            }
        }
        return false
    }

    private func getSnapshot() -> (DNSProvider, [DNSProvider], String, [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (activeProvider, allProviders, fallbackServer, excludedDomains)
    }

    private func getCached(key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[key] else { return nil }
        if entry.expiresAt > Date() {
            return entry.data
        }
        cache.removeValue(forKey: key)
        return nil
    }

    private func setCached(key: String, data: Data, ttlSeconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if cache.count > 512 {
            cache.removeAll()
        }
        cache[key] = (data, Date().addingTimeInterval(ttlSeconds))
    }
}
