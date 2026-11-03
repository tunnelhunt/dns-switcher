import Foundation

public enum DNSPacket {
    /// Extracts the queried domain name and qtype (e.g. 1 = A, 28 = AAAA, 65 = HTTPS) from a DNS wire-format query.
    public static func parseQuestion(from data: Data) -> (domain: String, qtype: UInt16)? {
        guard data.count >= 12 else { return nil }
        var idx = 12
        var labels: [String] = []

        while idx < data.count {
            let length = Int(data[idx])
            if length == 0 {
                idx += 1
                break
            }
            // Pointer compression shouldn't occur in first question QNAME, but guard anyway
            if (length & 0xC0) == 0xC0 {
                return nil
            }
            idx += 1
            guard idx + length <= data.count else { return nil }
            let labelData = data.subdata(in: idx..<(idx + length))
            if let label = String(data: labelData, encoding: .utf8) {
                labels.append(label.lowercased())
            }
            idx += length
        }

        guard idx + 4 <= data.count else { return nil }
        let qtype = (UInt16(data[idx]) << 8) | UInt16(data[idx + 1])
        return (labels.joined(separator: "."), qtype)
    }

    /// Builds a standard DNS wire-format query for an A record (qtype = 1, qclass = 1).
    public static func buildAQuery(domain: String, txID: UInt16 = 0) -> Data {
        var packet = Data()
        packet.append(UInt8((txID >> 8) & 0xFF))
        packet.append(UInt8(txID & 0xFF))
        // Flags: Standard query, Recursion Desired (0x0100)
        packet.append(contentsOf: [0x01, 0x00])
        // QDCOUNT = 1, ANCOUNT = 0, NSCOUNT = 0, ARCOUNT = 0
        packet.append(contentsOf: [0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        for part in domain.split(separator: ".") {
            let bytes = Array(part.utf8)
            guard bytes.count < 64 else { continue }
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        packet.append(0x00) // root label
        // QTYPE = A (1), QCLASS = IN (1)
        packet.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
        return packet
    }

    /// Extracts all IPv4 A record strings from a DNS wire-format response.
    public static func extractARecords(from data: Data) -> [String] {
        guard data.count >= 12 else { return [] }
        let qdCount = (Int(data[4]) << 8) | Int(data[5])
        let anCount = (Int(data[6]) << 8) | Int(data[7])
        guard anCount > 0 else { return [] }

        var idx = 12
        // Skip questions
        for _ in 0..<qdCount {
            guard let nextIdx = skipName(in: data, from: idx), nextIdx + 4 <= data.count else {
                return []
            }
            idx = nextIdx + 4
        }

        var ips: [String] = []
        for _ in 0..<anCount {
            guard let afterName = skipName(in: data, from: idx), afterName + 10 <= data.count else {
                break
            }
            idx = afterName
            let rtype = (UInt16(data[idx]) << 8) | UInt16(data[idx + 1])
            let rdLength = (Int(data[idx + 8]) << 8) | Int(data[idx + 9])
            idx += 10
            guard idx + rdLength <= data.count else { break }
            if rtype == 1 && rdLength == 4 {
                let ip = "\(data[idx]).\(data[idx + 1]).\(data[idx + 2]).\(data[idx + 3])"
                ips.append(ip)
            }
            idx += rdLength
        }
        return ips
    }

    private static func skipName(in data: Data, from start: Int) -> Int? {
        var idx = start
        var jumps = 0
        while idx < data.count {
            let len = Int(data[idx])
            if len == 0 {
                return idx + 1
            }
            if (len & 0xC0) == 0xC0 {
                guard idx + 1 < data.count else { return nil }
                return idx + 2
            }
            idx += 1 + len
            jumps += 1
            if jumps > 128 { return nil }
        }
        return nil
    }

    /// Rewrites the 2-byte Transaction ID of a DNS message.
    public static func withTransactionID(_ txID: UInt16, in packet: Data) -> Data {
        guard packet.count >= 2 else { return packet }
        var copy = packet
        copy[0] = UInt8((txID >> 8) & 0xFF)
        copy[1] = UInt8(txID & 0xFF)
        return copy
    }

    /// Reads the 2-byte Transaction ID from a DNS message.
    public static func transactionID(of packet: Data) -> UInt16 {
        guard packet.count >= 2 else { return 0 }
        return (UInt16(packet[0]) << 8) | UInt16(packet[1])
    }

    /// Synthesizes a direct DNS response for a query (either A records if qtype == 1, or empty NOERROR if AAAA/HTTPS for bootstrap host).
    public static func synthesizeBootstrapResponse(for query: Data, ipv4List: [String], ttl: UInt32 = 300) -> Data? {
        guard query.count >= 12, let question = parseQuestion(from: query) else { return nil }
        // Find end of first question section
        guard let afterQName = skipName(in: query, from: 12), afterQName + 4 <= query.count else { return nil }
        let questionSection = query.subdata(in: 12..<(afterQName + 4))

        var resp = Data()
        // Copy Transaction ID
        resp.append(query[0])
        resp.append(query[1])
        // Flags: QR=1, Opcode=0, AA=0, TC=0, RD=1, RA=1, RCODE=0 -> 0x8180
        resp.append(contentsOf: [0x81, 0x80])
        // QDCOUNT = 1
        resp.append(contentsOf: [0x00, 0x01])

        // Only return A records if QTYPE == 1 (A) or 255 (ANY)
        let validIPs: [[UInt8]] = (question.qtype == 1 || question.qtype == 255) ? ipv4List.compactMap { ipStr in
            let parts = ipStr.split(separator: ".").compactMap { UInt8($0) }
            return parts.count == 4 ? parts : nil
        } : []

        let anCount = UInt16(validIPs.count)
        resp.append(UInt8((anCount >> 8) & 0xFF))
        resp.append(UInt8(anCount & 0xFF))
        // NSCOUNT = 0, ARCOUNT = 0
        resp.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        // Question section
        resp.append(questionSection)

        // Answer section
        for octets in validIPs {
            // Name pointer to offset 12 (0xC00C)
            resp.append(contentsOf: [0xC0, 0x0C])
            // TYPE = A (1), CLASS = IN (1)
            resp.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
            // TTL
            resp.append(UInt8((ttl >> 24) & 0xFF))
            resp.append(UInt8((ttl >> 16) & 0xFF))
            resp.append(UInt8((ttl >> 8) & 0xFF))
            resp.append(UInt8(ttl & 0xFF))
            // RDLENGTH = 4
            resp.append(contentsOf: [0x00, 0x04])
            resp.append(contentsOf: octets)
        }
        return resp
    }

    /// Returns a human-friendly name for common DNS query types (A, AAAA, HTTPS, etc.).
    public static func qtypeName(for qtype: UInt16) -> String {
        switch qtype {
        case 1: return "A"
        case 28: return "AAAA"
        case 5: return "CNAME"
        case 15: return "MX"
        case 16: return "TXT"
        case 65: return "HTTPS"
        case 12: return "PTR"
        case 33: return "SRV"
        case 257: return "CAA"
        case 255: return "ANY"
        default: return "TYPE\(qtype)"
        }
    }

    /// Extracts the minimum positive TTL across all answer records, or fallback defaultTTL.
    public static func extractMinTTL(from data: Data, defaultTTL: UInt32 = 60) -> UInt32 {
        guard data.count >= 12 else { return defaultTTL }
        let qdCount = (Int(data[4]) << 8) | Int(data[5])
        let anCount = (Int(data[6]) << 8) | Int(data[7])
        guard anCount > 0 else { return defaultTTL }

        var idx = 12
        for _ in 0..<qdCount {
            guard let nextIdx = skipName(in: data, from: idx), nextIdx + 4 <= data.count else {
                return defaultTTL
            }
            idx = nextIdx + 4
        }

        var minTTL = UInt32.max
        for _ in 0..<anCount {
            guard let afterName = skipName(in: data, from: idx), afterName + 10 <= data.count else {
                break
            }
            idx = afterName
            let ttl = (UInt32(data[idx + 4]) << 24) |
                      (UInt32(data[idx + 5]) << 16) |
                      (UInt32(data[idx + 6]) << 8) |
                       UInt32(data[idx + 7])
            let rdLength = (Int(data[idx + 8]) << 8) | Int(data[idx + 9])
            idx += 10
            if ttl > 0 && ttl < minTTL {
                minTTL = ttl
            }
            guard idx + rdLength <= data.count else { break }
            idx += rdLength
        }
        return minTTL == UInt32.max ? defaultTTL : minTTL
    }

    /// Builds a standard DNS failure response (e.g. SERVFAIL RCODE 2) copying the query Transaction ID and question.
    public static func buildFailureResponse(for query: Data, rcode: UInt8 = 2) -> Data {
        guard query.count >= 12 else {
            return Data([0x00, 0x00, 0x81, 0x80 | (rcode & 0x0F), 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        }
        var resp = Data()
        // Transaction ID
        resp.append(query[0])
        resp.append(query[1])
        // Flags: QR=1 (response), copy RD (bit 0 of byte 2), RA=1 (bit 7 of byte 3), RCODE
        let rdBit = query[2] & 0x01
        let byte2: UInt8 = 0x80 | rdBit
        let byte3: UInt8 = 0x80 | (rcode & 0x0F)
        resp.append(contentsOf: [byte2, byte3])
        // Copy QDCOUNT
        resp.append(query[4])
        resp.append(query[5])
        // ANCOUNT = 0, NSCOUNT = 0, ARCOUNT = 0
        resp.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        // Append Question section if parseable
        if let afterQ = skipName(in: query, from: 12), afterQ + 4 <= query.count {
            resp.append(query.subdata(in: 12..<(afterQ + 4)))
        }
        return resp
    }

    /// Encodes DNS wire-format message (with txID=0) into RFC 8484 base64url without padding.
    public static func base64URLEncode(_ data: Data) -> String {
        let zeroed = withTransactionID(0, in: data)
        return zeroed.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
