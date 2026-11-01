import Foundation
import Darwin

/// Runs as a privileged background bridge (`DNSSwitcher --bridge`) on 127.0.0.1:53 (UDP & TCP),
/// forwarding DNS queries to the user-space MenuBar app on 127.0.0.1:53535.
/// Includes an automatic failsafe fallback to 77.88.8.8:53 / 1.1.1.1:53 if the MenuBar app is not running.
public enum Port53Bridge {
    public static let listenIP = "127.0.0.1"
    public static let listenPort: UInt16 = 53
    public static let appProxyPort: UInt16 = 53535
    public static let defaultFallbackDNSServer = "77.88.8.8"

    /// Returns the configured fallback DNS server IP (shared by the Menu Bar app via `/tmp/dnsswitcher-fallback-dns.txt`,
    /// or detected from DHCP / default fallback if not yet written).
    public static func currentFallbackDNSServer() -> String {
        if let saved = try? String(contentsOfFile: SystemDNSManager.fallbackConfigPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           SystemDNSManager.isValidNonLoopbackIPv4(saved) {
            return saved
        }
        return SystemDNSManager.detectDHCPDNSServer() ?? defaultFallbackDNSServer
    }

    public static func runDaemon() -> Never {
        signal(SIGPIPE, SIG_IGN)
        fputs("[DNSSwitcher Bridge] Starting on \(listenIP):\(listenPort) -> \(listenIP):\(appProxyPort)\n", stderr)

        let udpThread = Thread {
            runUDPLoop()
        }
        udpThread.name = "com.dnsswitcher.bridge.udp"
        udpThread.start()

        runTCPLoop()
        dispatchMain()
    }

    /// Checks whether 127.0.0.1:53 is already bound and listening (i.e., bridge daemon is active).
    public static func isBridgeRunning() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        var addr = makeSockAddr(ip: listenIP, port: listenPort)
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if res == 0 { return true }
        if errno == EINPROGRESS {
            var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            let pr = poll(&pfd, 1, 250)
            if pr > 0 {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len)
                return err == 0
            }
        }
        return false
    }

    private static func runUDPLoop() {
        let serverSock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard serverSock >= 0 else {
            fputs("[DNSSwitcher Bridge] Failed to create UDP socket: \(errno)\n", stderr)
            return
        }
        var yes: Int32 = 1
        setsockopt(serverSock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(serverSock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var bindAddr = makeSockAddr(ip: listenIP, port: listenPort)
        let bindRes = withUnsafePointer(to: &bindAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            fputs("[DNSSwitcher Bridge] Failed to bind UDP \(listenIP):\(listenPort) errno=\(errno)\n", stderr)
            close(serverSock)
            return
        }

        let sendLock = NSLock()
        var buf = [UInt8](repeating: 0, count: 4096)

        while true {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &clientAddr) { clientPtr in
                clientPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    recvfrom(serverSock, &buf, buf.count, 0, saPtr, &clientLen)
                }
            }
            guard n > 0 else { continue }
            let queryData = Data(bytes: buf, count: n)
            let capturedClient = clientAddr

            DispatchQueue.global(qos: .userInitiated).async {
                guard let response = forwardUDP(query: queryData) else { return }
                sendLock.lock()
                defer { sendLock.unlock() }
                var dest = capturedClient
                response.withUnsafeBytes { rawBuf in
                    guard let base = rawBuf.baseAddress else { return }
                    withUnsafePointer(to: &dest) { destPtr in
                        destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                            _ = sendto(serverSock, base, response.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }

    private static func forwardUDP(query: Data) -> Data? {
        // 1. Try forwarding to user-space MenuBar app on 127.0.0.1:53535
        if let reply = sendUDP(query: query, host: listenIP, port: appProxyPort, timeoutMs: 2500) {
            return reply
        }
        // 2. Failsafe: if MenuBar app isn't running, forward to configured fallback DNS so user never loses internet
        let fallbackHost = currentFallbackDNSServer()
        return sendUDP(query: query, host: fallbackHost, port: 53, timeoutMs: 2000)
    }

    public static func sendUDP(query: Data, host: String, port: UInt16, timeoutMs: Int32) -> Data? {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var destAddr = makeSockAddr(ip: host, port: port)
        let connectRes = withUnsafePointer(to: &destAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectRes == 0 else { return nil }

        let sent = query.withUnsafeBytes { rawBuf -> Int in
            guard let base = rawBuf.baseAddress else { return -1 }
            return send(sock, base, query.count, 0)
        }
        guard sent == query.count else { return nil }

        var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
        let pr = poll(&pfd, 1, timeoutMs)
        guard pr > 0 && (pfd.revents & Int16(POLLIN)) != 0 else { return nil }

        var rxBuf = [UInt8](repeating: 0, count: 4096)
        let rxLen = recv(sock, &rxBuf, rxBuf.count, 0)
        guard rxLen > 0 else { return nil }
        return Data(bytes: rxBuf, count: rxLen)
    }

    private static func runTCPLoop() {
        let serverSock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard serverSock >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(serverSock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(serverSock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var bindAddr = makeSockAddr(ip: listenIP, port: listenPort)
        let bindRes = withUnsafePointer(to: &bindAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0, listen(serverSock, 64) == 0 else {
            close(serverSock)
            return
        }

        while true {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientSock = withUnsafeMutablePointer(to: &clientAddr) { clientPtr in
                clientPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    accept(serverSock, saPtr, &clientLen)
                }
            }
            guard clientSock >= 0 else { continue }
            DispatchQueue.global(qos: .userInitiated).async {
                handleTCPClient(clientSock)
            }
        }
    }

    private static func handleTCPClient(_ clientSock: Int32) {
        defer { close(clientSock) }
        var lenBytes = [UInt8](repeating: 0, count: 2)
        guard recvAll(sock: clientSock, buf: &lenBytes, count: 2) else { return }
        let msgLen = (Int(lenBytes[0]) << 8) | Int(lenBytes[1])
        guard msgLen > 0 && msgLen <= 65535 else { return }

        var queryBytes = [UInt8](repeating: 0, count: msgLen)
        guard recvAll(sock: clientSock, buf: &queryBytes, count: msgLen) else { return }
        let queryData = Data(queryBytes)

        guard let response = forwardUDP(query: queryData) else { return }
        let rLen = response.count
        var out = Data([UInt8((rLen >> 8) & 0xFF), UInt8(rLen & 0xFF)])
        out.append(response)
        _ = out.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return -1 }
            return send(clientSock, base, out.count, 0)
        }
    }

    private static func recvAll(sock: Int32, buf: inout [UInt8], count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = buf.withUnsafeMutableBytes { rawBuf -> Int in
                guard let base = rawBuf.baseAddress else { return -1 }
                return recv(sock, base.advanced(by: offset), count - offset, 0)
            }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    public static func makeSockAddr(ip: String, port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        _ = ip.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        return addr
    }
}
