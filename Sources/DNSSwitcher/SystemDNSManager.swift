import Foundation

public enum SystemDNSManager {
    public static let daemonLabel = "com.dnsswitcher.bridge"
    public static let daemonPlistPath = "/Library/LaunchDaemons/com.dnsswitcher.bridge.plist"
    public static let bridgeBinaryDir = "/Library/Application Support/DNSSwitcher"
    public static let bridgeBinaryPath = "/Library/Application Support/DNSSwitcher/DNSSwitcherBridge"
    public static let fallbackConfigPath = "/tmp/dnsswitcher-fallback-dns.txt"

    /// Detects the underlying DHCP DNS server (or router gateway) assigned to the active network interface,
    /// unaffected by manual `127.0.0.1` DNS override.
    public static func detectDHCPDNSServer() -> String? {
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
        try? resolved.write(toFile: fallbackConfigPath, atomically: true, encoding: .utf8)
        return resolved
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

    /// Reads the currently configured DNS servers on the primary physical service (e.g., Wi-Fi).
    public static func currentSystemDNSServers() -> [String] {
        let services = detectPhysicalNetworkServices()
        guard let primary = services.first,
              let output = runCommand("/usr/sbin/networksetup", ["-getdnsservers", primary]) else {
            return []
        }
        if output.contains("There aren't any DNS Servers") {
            return []
        }
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
