import Foundation
import Darwin

// Which network a connection's video and audio travel over. The pure rules live here: reading an
// IP address, which ranges are the LAN and which are Tailscale, and which peers can be reached
// without a public STUN server.

/// An IPv4 or IPv6 address, read from the text form an address or an ICE candidate carries.
struct IPAddress: Hashable, CustomStringConvertible {
    enum Family: Hashable {
        case v4
        case v6
    }

    let family: Family
    /// 4 bytes for IPv4, 16 for IPv6, in network order.
    let bytes: [UInt8]

    /// Reads `192.168.0.131`, `fd7a:115c:a1e0::9428:4907`, `[fe80::1]` or `fe80::1%en0` (the zone
    /// is dropped); nil for anything else, host names included.
    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[") && text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast())
        }
        if let zone = text.firstIndex(of: "%") {
            text = String(text[..<zone])
        }
        guard !text.isEmpty else { return nil }

        var v4 = in_addr()
        if text.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            family = .v4
            bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }
        var v6 = in6_addr()
        if text.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            family = .v6
            bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return
        }
        return nil
    }

    init?(family: Family, bytes: [UInt8]) {
        guard bytes.count == (family == .v4 ? 4 : 16) else { return nil }
        self.family = family
        self.bytes = bytes
    }

    /// The usual text form: dotted quad, or compressed IPv6.
    var description: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok: Bool = bytes.withUnsafeBytes { raw in
            inet_ntop(family == .v4 ? AF_INET : AF_INET6, raw.baseAddress, &buffer, socklen_t(buffer.count)) != nil
        }
        return ok ? String(cString: buffer) : bytes.map(String.init).joined(separator: ".")
    }

    /// Whether the first `length` bits match `prefix`'s.
    func hasPrefix(_ prefix: [UInt8], length: Int) -> Bool {
        guard prefix.count * 8 >= length, bytes.count * 8 >= length else { return false }
        var remaining = length
        var index = 0
        while remaining > 0 {
            let bits = min(8, remaining)
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            if bytes[index] & mask != prefix[index] & mask { return false }
            remaining -= bits
            index += 1
        }
        return true
    }

    /// Tailscale's ranges: 100.64.0.0/10 (its CGNAT block) and fd7a:115c:a1e0::/48.
    var isTailscale: Bool {
        switch family {
        case .v4: return hasPrefix([100, 64], length: 10)
        case .v6: return hasPrefix([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0], length: 48)
        }
    }

    /// RFC 1918: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16.
    var isPrivateLAN: Bool {
        guard family == .v4 else { return false }
        return hasPrefix([10], length: 8) || hasPrefix([172, 16], length: 12) || hasPrefix([192, 168], length: 16)
    }

    /// 169.254.0.0/16 and fe80::/10.
    var isLinkLocal: Bool {
        switch family {
        case .v4: return hasPrefix([169, 254], length: 16)
        case .v6: return hasPrefix([0xFE, 0x80], length: 10)
        }
    }

    /// 127.0.0.0/8 and ::1.
    var isLoopback: Bool {
        switch family {
        case .v4: return hasPrefix([127], length: 8)
        case .v6: return bytes == [UInt8](repeating: 0, count: 15) + [1]
        }
    }
}

enum MediaNetworkRules {
    /// Whether a KVM at `host` can be reached with host candidates alone, so a connect to it needs
    /// no public STUN server: RFC 1918, loopback and link-local IPv4, Tailscale (100.64.0.0/10,
    /// fd7a:115c:a1e0::/48 and `*.ts.net`), `.local` and `localhost`, and a single-label name such
    /// as `mdesktopkvm`, which only a local resolver (Tailscale's MagicDNS, the router's DNS, a
    /// hosts file) can answer.
    static func isDirectlyReachable(host: String) -> Bool {
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix("[") && name.hasSuffix("]") {
            name = String(name.dropFirst().dropLast())
        }
        if name.hasSuffix(".") {
            name.removeLast()
        }
        guard !name.isEmpty else { return false }

        if let address = IPAddress(name) {
            switch address.family {
            case .v4:
                return address.isPrivateLAN || address.isLoopback || address.isLinkLocal || address.isTailscale
            case .v6:
                return address.isTailscale
            }
        }
        if name == "localhost" || name.hasSuffix(".local") || name.hasSuffix(".ts.net") {
            return true
        }
        // A name with no dot that is not an address (an IPv6 address has colons, not dots).
        return !name.contains(".") && !name.contains(":")
    }
}
