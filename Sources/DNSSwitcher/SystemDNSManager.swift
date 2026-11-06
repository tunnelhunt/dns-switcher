import Foundation
import SystemConfiguration

public enum SystemDNSManager {
    public static let daemonLabel = "com.dnsswitcher.bridge"
    public static let daemonPlistPath = "/Library/LaunchDaemons/com.dnsswitcher.bridge.plist"
    public static let bridgeBinaryDir = "/Library/Application Support/DNSSwitcher"
    public static let bridgeBinaryPath = "/Library/Application Support/DNSSwitcher/DNSSwitcherBridge"
    public static let fallbackConfigPath = "/tmp/dnsswitcher-fallback-dns.txt"
    public static let requiredBridgeVersion = 2
    public static let bridgeVersionPath = "/Library/Application Support/DNSSwitcher/bridge.version"

    /// Detects the underlying DHCP DNS server (or router gateway) assigned to the active network interface,
    /// unaffected by manual `127.0.0.1` DNS override.
    public static func detectDHCPDNSServer() -> String? {
        if let store = SCDynamicStoreCreate(nil, "DNSSwitcher" as CFString, nil, nil),
           let globalIPv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            if let primaryService = globalIPv4["PrimaryService"] as? String,
               let stateDNS = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(primaryService)/DNS" as CFString) as? [String: Any],
               let addrs = stateDNS["ServerAddresses"] as? [String] {
                for ip in addrs where isValidNonLoopbackIPv4(ip) {
                    return ip
                }
            }
            if let router = globalIPv4["Router"] as? String, isValidNonLoopbackIPv4(router) {
                return router
            }
        }

        let interfaces = ["en0", "en1", "en2", "en3"]
        for iface in interfaces {
            if let out = runCommand("/usr/sbin/ipconfig", ["getoption", iface, "domain_name_server"]) {
                let candidate = out
                    .components(separatedBy: .whitespacesAndNewlines)
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if isValidNonLoopbackIPv4(candidate) {
                    return candidate
                }
            }
        }
        for iface in interfaces {
            if let out = runCommand("/usr/sbin/ipconfig", ["getoption", iface, "router"]) {
                let candidate = out
                    .components(separatedBy: .whitespacesAndNewlines)
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if isValidNonLoopbackIPv4(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    public static func isValidNonLoopbackIPv4(_ ip: String) -> Bool {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("127."), trimmed != "0.0.0.0" else { return false }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let byte = UInt8(part) else { return false }
            _ = byte
        }
        return true
    }

    /// Resolves the effective IPv4 address for fallback/bootstrap DNS requests and persists it for the bridge daemon.
    public static func resolveFallbackDNSServer(option: FallbackDNSOption, customIP: String) -> String {
        let resolved: String
        switch option {
        case .disabled:
            resolved = "disabled"
        case .system:
            resolved = detectDHCPDNSServer() ?? "77.88.8.8"
        case .yandex:
            resolved = "77.88.8.8"
        case .cloudflare:
            resolved = "1.1.1.1"
        case .google:
            resolved = "8.8.8.8"
        case .custom:
            let clean = customIP.trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidNonLoopbackIPv4(clean) {
                resolved = clean
            } else {
                resolved = detectDHCPDNSServer() ?? "77.88.8.8"
            }
        }
        if (try? String(contentsOfFile: fallbackConfigPath, encoding: .utf8)) != resolved {
            try? resolved.write(toFile: fallbackConfigPath, atomically: true, encoding: .utf8)
        }
        return resolved
    }

    /// Normalizes a user-entered domain exclusion rule (e.g. `*.corp.example.com`, `.example.com`, `https://git.corp.local/path` -> `corp.example.com`, `example.com`, `git.corp.local`).
    public static func normalizeDomainRule(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }

        if s.contains("://"), let url = URL(string: s), let host = url.host {
            s = host.lowercased()
        } else if let slashIdx = s.firstIndex(of: "/") {
            s = String(s[..<slashIdx])
        }
        if let colonIdx = s.firstIndex(of: ":") {
            s = String(s[..<colonIdx])
        }

        while s.hasPrefix("*.") || s.hasPrefix(".") || s.hasPrefix("*") {
            if s.hasPrefix("*.") {
                s.removeFirst(2)
            } else {
                s.removeFirst(1)
            }
        }
        while s.hasSuffix(".") {
            s.removeLast()
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        return s
    }

    /// Detects active VPN DNS servers and underlying system/DHCP DNS servers in priority order:
    /// 1. VPN / tunnel DNS servers (`utun*`, `ppp*`, `ipsec*`, or non-`en*` network services in `SCDynamicStore`)
    /// 2. Physical interface DHCP DNS servers (`State:/Network/Service/*/DNS` on `en*` and `ipconfig getoption`)
    /// 3. Configured fallback DNS server (if enabled and valid IPv4)
    public static func detectSystemAndVPNDNSServers(fallbackIP: String?, ignoringBootstrapIPs: Set<String> = []) -> [String] {
        var vpnServers: [String] = []
        var dhcpServers: [String] = []

        if let store = SCDynamicStoreCreate(nil, "DNSSwitcher" as CFString, nil, nil) {
            var serviceIDs = Set<String>()
            for pattern in ["State:/Network/Service/.*/DNS", "Setup:/Network/Service/.*/DNS"] {
                if let keys = SCDynamicStoreCopyKeyList(store, pattern as CFString) as? [String] {
                    for key in keys {
                        let parts = key.split(separator: "/")
                        if parts.count >= 4 {
                            serviceIDs.insert(String(parts[3]))
                        }
                    }
                }
            }

            for serviceID in serviceIDs {
                var iface = ""
                if let ifaceDict = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(serviceID)/Interface" as CFString) as? [String: Any],
                   let name = ifaceDict["DeviceName"] as? String {
                    iface = name
                } else if let ipv6Dict = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(serviceID)/IPv6" as CFString) as? [String: Any],
                          let name = ipv6Dict["InterfaceName"] as? String, !name.hasPrefix("en") {
                    iface = name
                } else if let ipv4Dict = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(serviceID)/IPv4" as CFString) as? [String: Any],
                          let name = ipv4Dict["InterfaceName"] as? String ?? ipv4Dict["ConfirmedInterfaceName"] as? String {
                    // If OverridePrimary is set on a service without a Setup Interface dict, it is a VPN tunnel (e.g. GlobalProtect gpd.pan)
                    if let overridePrimary = ipv4Dict["OverridePrimary"] as? Int, overridePrimary == 1 {
                        iface = "utun_vpn"
                    } else {
                        iface = name
                    }
                }

                let isPhysicalEn = iface.hasPrefix("en")

                // Read State DNS (dynamic from DHCP or VPN tunnel)
                if let stateDNS = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(serviceID)/DNS" as CFString) as? [String: Any],
                   let addrs = stateDNS["ServerAddresses"] as? [String] {
                    for ip in addrs where isValidNonLoopbackIPv4(ip) && !ignoringBootstrapIPs.contains(ip) {
                        if isPhysicalEn {
                            dhcpServers.append(ip)
                        } else {
                            vpnServers.append(ip)
                        }
                    }
                }

                // Read Setup DNS only for non-physical (VPN) services so we don't pick up our own 127.0.0.1 / custom override on en0
                if !isPhysicalEn,
                   let setupDNS = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(serviceID)/DNS" as CFString) as? [String: Any],
                   let addrs = setupDNS["ServerAddresses"] as? [String] {
                    for ip in addrs where isValidNonLoopbackIPv4(ip) && !ignoringBootstrapIPs.contains(ip) {
                        vpnServers.append(ip)
                    }
                }
            }
        }

        if dhcpServers.isEmpty, let dhcp = detectDHCPDNSServer(), !ignoringBootstrapIPs.contains(dhcp) {
            dhcpServers.append(dhcp)
        }

        var ordered: [String] = []
        let extra = (fallbackIP != nil && isValidNonLoopbackIPv4(fallbackIP!)) ? [fallbackIP!] : []
        for ip in vpnServers + dhcpServers + extra {
            if isValidNonLoopbackIPv4(ip) && !ordered.contains(ip) {
                ordered.append(ip)
            }
        }
        return ordered
    }

    /// Returns all active physical network service names (e.g., ["Wi-Fi", "Ethernet"]) that have an `enX` device.
    public static func detectPhysicalNetworkServices() -> [String] {
        guard let output = runCommand("/usr/sbin/networksetup", ["-listnetworkserviceorder"]) else {
            return ["Wi-Fi"]
        }
        var services: [String] = []
        let lines = output.components(separatedBy: .newlines)
        var currentService: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match e.g. "(1) Wi-Fi"
            if trimmed.hasPrefix("("), let closeParen = trimmed.firstIndex(of: ")") {
                let prefix = trimmed[trimmed.index(after: trimmed.startIndex)..<closeParen]
                if Int(prefix) != nil {
                    let name = trimmed[trimmed.index(after: closeParen)...].trimmingCharacters(in: .whitespaces)
                    if !name.hasPrefix("*") && !name.isEmpty {
                        currentService = name
                    } else {
                        currentService = nil
                    }
                    continue
                }
            }
            // Match e.g. "(Hardware Port: Wi-Fi, Device: en0)"
            if let service = currentService, trimmed.hasPrefix("(Hardware Port:"), trimmed.contains("Device: en") {
                services.append(service)
                currentService = nil
            }
        }
        return services.isEmpty ? ["Wi-Fi"] : services
    }

    /// Reads the currently configured DNS servers on the physical network services (e.g., Wi-Fi, Ethernet),
    /// unaffected by VPN `OverridePrimary` changes in `State:/Network/Global/IPv4`.
    public static func currentSystemDNSServers() -> [String] {
        if let store = SCDynamicStoreCreate(nil, "DNSSwitcher" as CFString, nil, nil) {
            // 1. Check PrimaryService first
            if let globalIPv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
               let primaryService = globalIPv4["PrimaryService"] as? String {
                if let setupDNS = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(primaryService)/DNS" as CFString) as? [String: Any],
                   let servers = setupDNS["ServerAddresses"] as? [String], !servers.isEmpty {
                    return servers
                }
            }

            // 2. Check all physical (en*) services in Setup:/Network/Service/*/DNS (covers VPN OverridePrimary e.g. GlobalProtect gpd.pan)
            if let keys = SCDynamicStoreCopyKeyList(store, "Setup:/Network/Service/.*/DNS" as CFString) as? [String] {
                var firstCustomServers: [String]? = nil
                for key in keys {
                    let parts = key.split(separator: "/")
                    guard parts.count >= 4 else { continue }
                    let serviceID = String(parts[3])

                    var iface = ""
                    if let ifaceDict = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(serviceID)/Interface" as CFString) as? [String: Any],
                       let name = ifaceDict["DeviceName"] as? String {
                        iface = name
                    } else if let ipv4Dict = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(serviceID)/IPv4" as CFString) as? [String: Any],
                              let name = ipv4Dict["InterfaceName"] as? String ?? ipv4Dict["ConfirmedInterfaceName"] as? String {
                        iface = name
                    }

                    guard iface.hasPrefix("en") else { continue }
                    if let setupDNS = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                       let servers = setupDNS["ServerAddresses"] as? [String], !servers.isEmpty {
                        if servers.contains("127.0.0.1") {
                            return servers
                        }
                        if firstCustomServers == nil {
                            firstCustomServers = servers
                        }
                    }
                }
                if let custom = firstCustomServers {
                    return custom
                }
            }

            // 3. Check global DNS for 127.0.0.1
            if let globalDNS = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
               let servers = globalDNS["ServerAddresses"] as? [String], servers.contains("127.0.0.1") {
                return servers
            }
        }

        let services = detectPhysicalNetworkServices()
        for service in services {
            if let output = runCommand("/usr/sbin/networksetup", ["-getdnsservers", service]) {
                if !output.contains("There aren't any DNS Servers") {
                    let servers = output
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if servers.contains("127.0.0.1") {
                        return servers
                    }
                }
            }
        }
        if let primary = services.first,
           let output = runCommand("/usr/sbin/networksetup", ["-getdnsservers", primary]),
           !output.contains("There aren't any DNS Servers") {
            return output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    /// Detects if macOS currently has a .mobileconfig Encrypted DNS profile overriding system DNS.
    public static func hasActiveMobileConfigDNSProfile() -> Bool {
        guard let output = runCommand("/usr/sbin/scutil", ["--dns"]) else { return false }
        return output.contains("DNS-over-HTTPS") || output.contains("DNS-over-TLS") || output.contains("HTTPS : ")
    }

    /// Sets DNS servers on all physical network interfaces (`127.0.0.1` for DoH proxy, IPs for plain DNS, or `Empty` to reset to DHCP).
    @discardableResult
    public static func setSystemDNS(servers: [String]) -> Bool {
        let services = detectPhysicalNetworkServices()
        let argsSuffix = servers.isEmpty ? ["Empty"] : servers
        var allSucceeded = true

        for service in services {
            let args = ["-setdnsservers", service] + argsSuffix
            if runCommand("/usr/sbin/networksetup", args) == nil {
                allSucceeded = false
            }
        }
        flushDNSCache()
        return allSucceeded
    }

    /// Resets system DNS back to automatic DHCP router DNS (`Empty`).
    @discardableResult
    public static func resetToSystemDefault() -> Bool {
        return setSystemDNS(servers: [])
    }

    /// Flushes the macOS user-space DNS cache (`dscacheutil -flushcache`).
    public static func flushDNSCache() {
        _ = runCommand("/usr/bin/dscacheutil", ["-flushcache"])
    }

    /// Checks whether the installed privileged bridge binary matches the required bridge protocol version.
    public static func isBridgeBinaryUpToDate() -> Bool {
        guard FileManager.default.fileExists(atPath: bridgeBinaryPath) else { return false }

        // 1. Check version file if present
        if let verStr = try? String(contentsOfFile: bridgeVersionPath, encoding: .utf8),
           let ver = Int(verStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return ver >= requiredBridgeVersion
        }

        // 2. If the bridge was modified on Nov 5, 2026 or later, it has the modern bridge logic
        if let attrs = try? FileManager.default.attributesOfItem(atPath: bridgeBinaryPath),
           let modDate = attrs[.modificationDate] as? Date,
           modDate.timeIntervalSince1970 > 1762300000 {
            return true
        }

        return Port53Bridge.isBridgeRunning()
    }

    /// Installs and starts the one-time LaunchDaemon that bridges 127.0.0.1:53 -> 127.0.0.1:53535.
    /// Uses standard macOS Touch ID / Administrator prompt once.
    public static func installPort53BridgeDaemon() -> Result<Void, Error> {
        let executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let resolvedExecPath = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(bridgeBinaryPath)</string>
                <string>--bridge</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardErrorPath</key>
            <string>/tmp/dnsswitcher-bridge.log</string>
        </dict>
        </plist>
        """

        let tempPlist = "/tmp/com.dnsswitcher.bridge.plist"
        do {
            try plistContent.write(toFile: tempPlist, atomically: true, encoding: .utf8)
        } catch {
            return .failure(error)
        }

        let shellScript = [
            "mkdir -p '\(bridgeBinaryDir)'",
            "cp -f '\(resolvedExecPath)' '\(bridgeBinaryPath)'",
            "chmod 755 '\(bridgeBinaryPath)'",
            "chown root:wheel '\(bridgeBinaryPath)'",
            "echo '\(requiredBridgeVersion)' > '\(bridgeVersionPath)'",
            "chmod 644 '\(bridgeVersionPath)'",
            "cp -f '\(tempPlist)' '\(daemonPlistPath)'",
            "chmod 644 '\(daemonPlistPath)'",
            "chown root:wheel '\(daemonPlistPath)'",
            "launchctl bootout system '\(daemonPlistPath)' 2>/dev/null || true",
            "launchctl bootstrap system '\(daemonPlistPath)'",
            "dscacheutil -flushcache || true",
            "killall -HUP mDNSResponder 2>/dev/null || true"
        ].joined(separator: " && ")

        return runPrivilegedShellScript(shellScript)
    }

    /// Removes the LaunchDaemon and resets DNS to default.
    public static func uninstallPort53BridgeDaemon() -> Result<Void, Error> {
        _ = resetToSystemDefault()
        let shellScript = [
            "launchctl bootout system '\(daemonPlistPath)' 2>/dev/null || true",
            "rm -f '\(daemonPlistPath)'",
            "rm -rf '\(bridgeBinaryDir)'",
            "dscacheutil -flushcache || true",
            "killall -HUP mDNSResponder 2>/dev/null || true"
        ].joined(separator: " && ")

        return runPrivilegedShellScript(shellScript)
    }

    private static func runPrivilegedShellScript(_ script: String) -> Result<Void, Error> {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", appleScript]
        let errPipe = Pipe()
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                return .success(())
            } else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Отменено пользователем"
                return .failure(NSError(domain: "DNSSwitcher", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errStr]))
            }
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    public static func runCommand(_ launchPath: String, _ arguments: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
