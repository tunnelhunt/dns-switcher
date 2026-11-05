import Foundation
import Darwin
import Network

public final class LocalDoHProxy: @unchecked Sendable {
    public static let shared = LocalDoHProxy()

    private let lock = NSLock()
    private var activeProvider: DNSProvider = DNSProvider.builtInProviders[0]
    private var allProviders: [DNSProvider] = DNSProvider.builtInProviders
    private var fallbackServer: String = Port53Bridge.defaultFallbackDNSServer
    private var isFallbackEnabled: Bool = true
    private var excludedDomains: [String] = []
    private var cachedSystemServers: (servers: [String], expiresAt: Date)?

    private struct CacheEntry {
        let data: Data
        let freshUntil: Date
        let staleUntil: Date
        let ips: [String]
    }
    private var cache: [String: CacheEntry] = [:]
    private var isRunning = false

    private struct DynamicBootstrapEntry {
        let ips: [String]
        let expiresAt: Date
    }
    private var dynamicBootstrapCache: [String: DynamicBootstrapEntry] = [:]

    private let urlSession: URLSession
    public var onQueryResolved: ((String, Int, Bool) -> Void)?
    public var onResolutionLogged: ((DNSResolutionRecord) -> Void)?

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 3.0
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

        let domain = active.dohHost.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        if active.bootstrapIPs.isEmpty && !domain.isEmpty {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                _ = self.resolveBootstrapIPs(domain: domain, providers: all, fallbackHost: nil)
            }
        }
    }

    public func setFallbackServer(_ ipOrDisabled: String) {
        lock.lock()
        let trimmed = ipOrDisabled.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "disabled" || trimmed == "none" {
            self.isFallbackEnabled = false
        } else if SystemDNSManager.isValidNonLoopbackIPv4(trimmed) {
            self.isFallbackEnabled = true
            self.fallbackServer = trimmed
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
        let (provider, providers, fallbackHost, fallbackActive, excluded) = getSnapshot()

        guard let question = DNSPacket.parseQuestion(from: query) else {
            if fallbackActive {
                return Port53Bridge.sendUDP(query: query, host: fallbackHost, port: 53, timeoutMs: 2000)
            } else {
                return DNSPacket.buildFailureResponse(for: query, rcode: 2)
            }
        }

        let qtypeStr = DNSPacket.qtypeName(for: question.qtype)

        // 1. Bootstrap anti-recursion check: if the query is for any DoH server hostname itself
        if let matchedProvider = providers.first(where: {
            let dohH = $0.dohHost.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let dotH = $0.dotHost.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let qd = question.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return (!dohH.isEmpty && dohH == qd) || (!dotH.isEmpty && dotH == qd)
        }) {
            // 1a. Static bootstrap IPs configured on provider
            if !matchedProvider.bootstrapIPs.isEmpty,
               let synth = DNSPacket.synthesizeBootstrapResponse(for: query, ipv4List: matchedProvider.bootstrapIPs) {
                logResolution(domain: question.domain, qtype: qtypeStr, source: .cache, serverName: "Bootstrap (Static)", latencyMs: 1, ips: matchedProvider.bootstrapIPs, success: true)
                return synth
            }

            // 1b. Dynamic bootstrap cache or resolve dynamically
            let start = DispatchTime.now()
            let systemFallback = fallbackActive ? fallbackHost : nil
            let bootstrapIPs = resolveBootstrapIPs(domain: question.domain, providers: providers, fallbackHost: systemFallback)

            if !bootstrapIPs.isEmpty,
               let synth = DNSPacket.synthesizeBootstrapResponse(for: query, ipv4List: bootstrapIPs) {
                let elapsedMs = max(1, Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000))
                logResolution(domain: question.domain, qtype: qtypeStr, source: .cache, serverName: "Bootstrap", latencyMs: elapsedMs, ips: bootstrapIPs, success: true)
                return synth
            }

            let elapsedMs = max(1, Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000))
            logResolution(domain: question.domain, qtype: qtypeStr, source: .error, serverName: "Bootstrap", latencyMs: elapsedMs, ips: [], success: false)
            return DNSPacket.buildFailureResponse(for: query, rcode: 2)
        }

        // 1b. Excluded domains check: bypass DoH and route through system / VPN DNS
        if Self.isDomainExcluded(question.domain, excludedDomains: excluded) {
            let start = DispatchTime.now()
            let systemFallback = fallbackActive ? fallbackHost : nil
            if let bypassReply = resolveViaSystemDNS(query: query, fallbackHost: systemFallback, providers: providers) {
                let elapsedMs = max(1, Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000))
                let ips = DNSPacket.extractARecords(from: bypassReply)
                logResolution(domain: question.domain, qtype: qtypeStr, source: .excluded, serverName: "VPN / DHCP", latencyMs: elapsedMs, ips: ips, success: true)
                return DNSPacket.withTransactionID(txID, in: bypassReply)
            }
            logResolution(domain: question.domain, qtype: qtypeStr, source: .error, serverName: "VPN / DHCP", latencyMs: 50, ips: [], success: false)
            return DNSPacket.buildFailureResponse(for: query, rcode: 2)
        }

        // 2. Check fresh in-memory TTL cache (instant response, <1ms)
        let cacheKey = "\(provider.id):\(question.domain):\(question.qtype)"
        if let freshCached = getFreshCached(key: cacheKey) {
            logResolution(domain: question.domain, qtype: qtypeStr, source: .cache, serverName: provider.name, latencyMs: 1, ips: freshCached.ips, success: true)
            return DNSPacket.withTransactionID(txID, in: freshCached.data)
        }

        // 3. Query active DoH provider via RFC 8484 GET (?dns=...)
        let start = DispatchTime.now()
        if let dohReply = await performDoHRequest(query: query, dohURL: provider.dohURL) {
            let elapsedMs = max(1, Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000))
            let ips = DNSPacket.extractARecords(from: dohReply)
            let ttl = DNSPacket.extractMinTTL(from: dohReply, defaultTTL: 60)
            setCached(key: cacheKey, data: dohReply, freshTTL: ttl, ips: ips)
            logResolution(domain: question.domain, qtype: qtypeStr, source: .doh, serverName: provider.name, latencyMs: elapsedMs, ips: ips, success: true)
            return DNSPacket.withTransactionID(txID, in: dohReply)
        }
        let failedElapsedMs = max(1, Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000))

        // 4. DoH request failed / timed out! Check Serve-Stale cache (RFC 8767: Serving Stale Data to Improve DNS Resiliency)
        if let staleCached = getStaleCached(key: cacheKey) {
            logResolution(domain: question.domain, qtype: qtypeStr, source: .staleCache, serverName: "\(provider.name) (кэш)", latencyMs: failedElapsedMs, ips: staleCached.ips, success: true)
            return DNSPacket.withTransactionID(txID, in: staleCached.data)
        }

        // 5. Fallback if enabled; otherwise return SERVFAIL (Server Failure)
        if fallbackActive {
            let fbStart = DispatchTime.now()
            if let fbReply = Port53Bridge.sendUDP(query: query, host: fallbackHost, port: 53, timeoutMs: 2000) {
                let fbElapsedMs = max(1, Int((DispatchTime.now().uptimeNanoseconds - fbStart.uptimeNanoseconds) / 1_000_000))
                let ips = DNSPacket.extractARecords(from: fbReply)
                logResolution(domain: question.domain, qtype: qtypeStr, source: .fallback, serverName: fallbackHost, latencyMs: fbElapsedMs, ips: ips, success: true)
                return DNSPacket.withTransactionID(txID, in: fbReply)
            }
        }

        // Fallback is disabled or failed -> immediate SERVFAIL response
        logResolution(domain: question.domain, qtype: qtypeStr, source: .error, serverName: provider.name, latencyMs: failedElapsedMs, ips: [], success: false)
        return DNSPacket.buildFailureResponse(for: query, rcode: 2)
    }

    private func logResolution(
        domain: String,
        qtype: String,
        source: ResolutionSource,
        serverName: String,
        latencyMs: Int,
        ips: [String],
        success: Bool
    ) {
        let isCached = (source == .cache || source == .staleCache)
        onQueryResolved?(domain, latencyMs, isCached)
        let record = DNSResolutionRecord(
            domain: domain,
            qtype: qtype,
            source: source,
            serverName: serverName,
            latencyMs: latencyMs,
            resolvedIPs: ips,
            isSuccess: success
        )
        onResolutionLogged?(record)
    }

    private func resolveViaSystemDNS(query: Data, fallbackHost: String?, providers: [DNSProvider]) -> Data? {
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

    private func getSystemAndVPNDNSServers(fallbackHost: String?, providers: [DNSProvider]) -> [String] {
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

    private func resolveBootstrapIPs(domain: String, providers: [DNSProvider], fallbackHost: String?) -> [String] {
        let cleanDomain = domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !cleanDomain.isEmpty else { return [] }

        lock.lock()
        if let cached = dynamicBootstrapCache[cleanDomain], cached.expiresAt > Date(), !cached.ips.isEmpty {
            let ips = cached.ips
            lock.unlock()
            return ips
        }
        lock.unlock()

        let aQuery = DNSPacket.buildAQuery(domain: cleanDomain)

        // 1. Resolve via system/VPN/DHCP DNS servers (router DNS)
        if let reply = resolveViaSystemDNS(query: aQuery, fallbackHost: fallbackHost, providers: providers) {
            let ips = DNSPacket.extractARecords(from: reply)
            if !ips.isEmpty {
                let ttl = max(1800, DNSPacket.extractMinTTL(from: reply, defaultTTL: 3600))
                lock.lock()
                dynamicBootstrapCache[cleanDomain] = DynamicBootstrapEntry(ips: ips, expiresAt: Date().addingTimeInterval(Double(ttl)))
                lock.unlock()
                return ips
            }
        }

        // 2. Emergency fallback rescue for the DoH server itself (77.88.8.8, 1.1.1.1, 8.8.8.8)
        for rescueIP in ["77.88.8.8", "1.1.1.1", "8.8.8.8"] {
            if let reply = Port53Bridge.sendUDP(query: aQuery, host: rescueIP, port: 53, timeoutMs: 1500) {
                let ips = DNSPacket.extractARecords(from: reply)
                if !ips.isEmpty {
                    lock.lock()
                    dynamicBootstrapCache[cleanDomain] = DynamicBootstrapEntry(ips: ips, expiresAt: Date().addingTimeInterval(3600))
                    lock.unlock()
                    return ips
                }
            }
        }

        return []
    }

    private func getCachedBootstrapIP(for host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let dyn = dynamicBootstrapCache[host.lowercased()], dyn.expiresAt > Date(), let first = dyn.ips.first {
            return first
        }
        return nil
    }

    public func performDoHRequest(query: Data, dohURL: String) async -> Data? {
        guard let parsed = URL(string: dohURL), let host = parsed.host else { return nil }
        let path = parsed.path.isEmpty ? "/dns-query" : parsed.path
        let fullPath = (parsed.query != nil && !parsed.query!.isEmpty) ? "\(path)?\(parsed.query!)" : path

        // 1. Direct-IP DoH via NWConnection (completely bypasses system DNS resolver & mDNSResponder)
        var destIP: String? = nil
        if SystemDNSManager.isValidNonLoopbackIPv4(host) {
            destIP = host
        } else {
            let (_, all, fallbackHost, _, _) = getSnapshot()
            if let matched = all.first(where: { $0.dohHost.lowercased() == host.lowercased() || $0.dotHost.lowercased() == host.lowercased() }),
               !matched.bootstrapIPs.isEmpty {
                destIP = matched.bootstrapIPs.first
            }
            if destIP == nil {
                destIP = getCachedBootstrapIP(for: host)
            }
            if destIP == nil {
                let resolved = resolveBootstrapIPs(domain: host, providers: all, fallbackHost: fallbackHost)
                destIP = resolved.first
            }
        }

        if let ip = destIP,
           let directReply = await performDoHDirect(host: host, ip: ip, path: fullPath, query: query),
           directReply.count >= 12 {
            return directReply
        }

        // 2. RFC 8484 GET fallback via URLSession
        let b64 = DNSPacket.base64URLEncode(query)
        let separator = dohURL.contains("?") ? "&" : "?"
        if let getURL = URL(string: "\(dohURL)\(separator)dns=\(b64)") {
            var getReq = URLRequest(url: getURL)
            getReq.httpMethod = "GET"
            getReq.setValue("application/dns-message", forHTTPHeaderField: "Accept")
            if let data = await executeHTTPRequest(getReq) {
                return data
            }
        }

        // 3. RFC 8484 POST fallback via URLSession
        if let postURL = URL(string: dohURL) {
            var postReq = URLRequest(url: postURL)
            postReq.httpMethod = "POST"
            postReq.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
            postReq.setValue("application/dns-message", forHTTPHeaderField: "Accept")
            postReq.httpBody = query
            if let data = await executeHTTPRequest(postReq) {
                return data
            }
        }

        return nil
    }

    private func performDoHDirect(host: String, ip: String, path: String, query: Data) async -> Data? {
        await withCheckedContinuation { continuation in
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, host)
            let params = NWParameters(tls: tlsOptions)
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ip), port: 443)
            let conn = NWConnection(to: endpoint, using: params)

            let lock = NSLock()
            var resumed = false
            func finish(_ result: Data?) {
                lock.lock()
                if resumed {
                    lock.unlock()
                    return
                }
                resumed = true
                lock.unlock()
                conn.cancel()
                continuation.resume(returning: result)
            }

            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    let b64 = DNSPacket.base64URLEncode(query)
                    let sep = path.contains("?") ? "&" : "?"
                    let reqPath = "\(path)\(sep)dns=\(b64)"
                    let http = "GET \(reqPath) HTTP/1.1\r\nHost: \(host)\r\nAccept: application/dns-message\r\nConnection: close\r\n\r\n"
                    conn.send(content: http.data(using: .utf8), completion: .contentProcessed { err in
                        if err != nil { finish(nil); return }
                        self.receiveFullHTTP(conn: conn, accumulated: Data()) { data in
                            finish(data)
                        }
                    })
                } else if case .failed = state {
                    finish(nil)
                } else if case .cancelled = state {
                    finish(nil)
                }
            }
            conn.start(queue: .global(qos: .userInitiated))

            // 2.5s Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
                finish(nil)
            }
        }
    }

    private func receiveFullHTTP(conn: NWConnection, accumulated: Data, completion: @escaping (Data?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, isComplete, err in
            if err != nil { completion(nil); return }
            var buffer = accumulated
            if let data = data {
                buffer.append(data)
            }
            let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
            if let sepRange = buffer.range(of: sep) {
                let headerData = buffer.subdata(in: 0..<sepRange.lowerBound)
                if let headerStr = String(data: headerData, encoding: .utf8) {
                    if !headerStr.contains("200 OK") {
                        completion(nil)
                        return
                    }
                    var contentLength: Int? = nil
                    for line in headerStr.components(separatedBy: "\r\n") {
                        let lower = line.lowercased()
                        if lower.hasPrefix("content-length:") {
                            let parts = line.split(separator: ":", maxSplits: 1)
                            if parts.count == 2, let len = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                                contentLength = len
                            }
                        }
                    }
                    let body = buffer.subdata(in: sepRange.upperBound..<buffer.count)
                    if let cl = contentLength {
                        if body.count >= cl {
                            completion(body.subdata(in: 0..<cl))
                            return
                        }
                    } else if isComplete {
                        completion(body)
                        return
                    }
                }
            }
            if isComplete {
                completion(nil)
            } else {
                self.receiveFullHTTP(conn: conn, accumulated: buffer, completion: completion)
            }
        }
    }

    private func executeHTTPRequest(_ request: URLRequest) async -> Data? {
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

    private func getSnapshot() -> (DNSProvider, [DNSProvider], String, Bool, [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (activeProvider, allProviders, fallbackServer, isFallbackEnabled, excludedDomains)
    }

    private func getFreshCached(key: String) -> CacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[key] else { return nil }
        if entry.freshUntil > Date() {
            return entry
        }
        return nil
    }

    private func getStaleCached(key: String) -> CacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[key] else { return nil }
        if entry.staleUntil > Date() {
            return entry
        }
        cache.removeValue(forKey: key)
        return nil
    }

    private func setCached(key: String, data: Data, freshTTL: UInt32, ips: [String]) {
        lock.lock()
        defer { lock.unlock() }
        if cache.count > 1024 {
            cache.removeAll()
        }
        let now = Date()
        let freshSecs = TimeInterval(max(15, min(freshTTL, 1800)))
        let freshUntil = now.addingTimeInterval(freshSecs)
        let staleUntil = now.addingTimeInterval(86400) // 24 hours stale retention for high availability
        cache[key] = CacheEntry(data: data, freshUntil: freshUntil, staleUntil: staleUntil, ips: ips)
    }
}
