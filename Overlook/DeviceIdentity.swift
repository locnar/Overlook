import Foundation

// A saved device is one machine with a nickname and one or more addresses: Michael reaches the
// same KVM as `192.168.0.131` on the LAN and as `mdesktopkvm` over Tailscale. This file holds the
// pure rules around that: which network an address is on, how an address is written down and
// typed in, and which old generated names are not nicknames.

/// Which network an address reaches a device over, as far as the address itself says.
/// Worked out from the address alone; there is no way to set it by hand.
enum AddressTag: String, Equatable, CaseIterable {
    case lan = "LAN"
    case tailscale = "Tailscale"

    /// `*.ts.net` names and 100.64.0.0/10 (Tailscale's CGNAT range) are Tailscale; RFC 1918
    /// IPv4 addresses are LAN; anything else gets no tag.
    static func classify(host: String) -> AddressTag? {
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasSuffix(".") {
            name.removeLast()
        }
        if name.hasSuffix(".ts.net") {
            return .tailscale
        }
        guard let octets = ipv4Octets(name) else { return nil }
        switch (octets[0], octets[1]) {
        case (100, 64...127):
            return .tailscale
        case (10, _), (172, 16...31), (192, 168):
            return .lan
        default:
            return nil
        }
    }

    /// The four octets of a dotted-quad IPv4 address, or nil for anything else.
    static func ipv4Octets(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard (1...3).contains(part.count),
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), (0...255).contains(value) else { return nil }
            octets.append(value)
        }
        return octets
    }
}

extension DeviceAddress {
    /// The network this address is on, if the address says.
    var tag: AddressTag? { AddressTag.classify(host: host) }

    /// The short form shown wherever a device is named by its address: the host, without the
    /// port when it is the scheme's own and without the tailnet suffix (`SessionLog.label`).
    var label: String { SessionLog.label(host: host, port: port) }

    /// The short form with its tag: `mdesktopkvm (Tailscale)`, `192.168.0.131 (LAN)`, `kvm.example`.
    var labelWithTag: String {
        tag.map { "\(label) (\($0.rawValue))" } ?? label
    }

    /// The full host and port, as the Edit sheet lists them: `192.168.0.131:443`, `[fd00::5]:8443`.
    var hostPort: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

/// Reads an address typed by the operator: Manual Connect, Quick Connect and the Edit sheet's `+`
/// all go through here, so they accept the same things.
enum AddressInput {
    enum Problem: Error, Equatable {
        case emptyHost
        case invalidHost
        case invalidPort

        var message: String {
            switch self {
            case .emptyHost: return "Enter a host name or IP address."
            case .invalidHost: return "That is not a valid host name or IP address."
            case .invalidPort: return "The port must be a number from 1 to 65535."
            }
        }
    }

    static let defaultPort = 443

    /// `hostField` may carry a scheme (`https://`), a port (`host:8443`, `[fd00::5]:8443`) and a
    /// trailing path, which are stripped; a port there wins over `portField`. An empty port field
    /// means 443.
    static func parse(_ hostField: String, port portField: String = "") -> Result<DeviceAddress, Problem> {
        var host = hostField.trimmingCharacters(in: .whitespacesAndNewlines)
        var portText = portField.trimmingCharacters(in: .whitespacesAndNewlines)

        if let scheme = host.range(of: "://") {
            host = String(host[scheme.upperBound...])
        }
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }

        if host.hasPrefix("[") {
            // Bracketed IPv6, optionally with a port after the bracket.
            guard let close = host.firstIndex(of: "]") else { return .failure(.invalidHost) }
            let rest = host[host.index(after: close)...]
            let inner = String(host[host.index(after: host.startIndex)..<close])
            if rest.hasPrefix(":"), rest.count > 1 {
                portText = String(rest.dropFirst())
            } else if !rest.isEmpty {
                return .failure(.invalidHost)
            }
            host = inner
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
            // host:port. More than one colon is a bare IPv6 address, which has no port.
            let maybeHost = String(host[..<colon])
            let maybePort = String(host[host.index(after: colon)...])
            if !maybeHost.isEmpty, !maybePort.isEmpty {
                host = maybeHost
                portText = maybePort
            }
        }

        guard !host.isEmpty else { return .failure(.emptyHost) }
        // A lone colon left over (`host:` with nothing after it) is not part of any host.
        if host.contains(":"), host.filter({ $0 == ":" }).count < 2 {
            return .failure(.invalidHost)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:%"))
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }),
              !host.hasPrefix("."), !host.hasPrefix("-") else {
            return .failure(.invalidHost)
        }

        let port: Int
        if portText.isEmpty {
            port = defaultPort
        } else {
            guard portText.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(portText), (1...65535).contains(value) else {
                return .failure(.invalidPort)
            }
            port = value
        }
        return .success(DeviceAddress(host: host, port: port))
    }
}

/// Names the app used to make up for a device, as opposed to one the operator chose.
enum DeviceNaming {
    /// What earlier versions called a device they had no name for: `Manual KVM @ host:port`,
    /// `KVM @ host:port`, `GLKVM @ host:port`, the last two sometimes with ` (Tailscale)` after.
    static let generatedPrefixes = ["Manual KVM @ ", "KVM @ ", "GLKVM @ "]

    static func isGenerated(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return generatedPrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// The nickname a saved record's old `name` becomes: nil for an empty or generated name.
    static func nickname(fromLegacyName name: String) -> String? {
        guard !isGenerated(name) else { return nil }
        return cleanNickname(name)
    }

    /// A nickname as typed: trimmed, and nil when nothing is left.
    static func cleanNickname(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Choosing the address a connect goes through. One connect makes one attempt, through one
/// address: a plain Connect uses the device's last-used address (its first when none is
/// recorded), the Connect menu uses the one picked, and a failure says which address it was and
/// leaves the choice of another to the operator. Nothing here tries a second address.
enum ConnectVia {
    static let menuTitle = "Connect via"
    static let lastUsedSuffix = " — last used"

    /// One row of the Connect menu.
    struct Item: Equatable {
        let address: DeviceAddress
        let title: String
        /// Shown with a checkmark.
        let isLastUsed: Bool
    }

    /// The Connect menu for `device`: every address in the operator's order, each with its tag,
    /// the last-used one checked and marked.
    static func items(for device: KVMDevice) -> [Item] {
        device.addresses.map { address in
            let isLastUsed = address == device.lastUsedAddress
            return Item(
                address: address,
                title: address.labelWithTag + (isLastUsed ? lastUsedSuffix : ""),
                isLastUsed: isLastUsed
            )
        }
    }

    /// What a plain Connect connects to.
    static func plainConnect(_ device: KVMDevice) -> KVMDevice {
        device.via(device.preferredAddress)
    }

    /// An address picked from the Connect menu: recorded as the device's last-used address at
    /// once, so the next plain Connect repeats the choice, and connected through as it is.
    @MainActor
    static func pick(_ address: DeviceAddress, of device: KVMDevice, in catalog: KVMDeviceManager) -> KVMDevice {
        catalog.setLastUsedAddress(address, for: device)
        let current = catalog.availableDevices.first { $0.id == device.id } ?? device
        return current.via(address)
    }

    /// The Connections panel's status line while connected.
    static func statusText(connectedThrough address: DeviceAddress) -> String {
        "Connected via \(address.labelWithTag)"
    }

    /// The alert for a connect that failed: the address it tried, and, for a device with others,
    /// where to pick one.
    static func failureMessage(address: DeviceAddress, deviceHasOtherAddresses: Bool, error: Error) -> String {
        let isUnreachable: Bool
        switch error {
        case KVMError.connectionFailed, KVMError.networkUnavailable, is URLError:
            isUnreachable = true
        default:
            isUnreachable = false
        }
        var text = isUnreachable
            ? "Couldn't reach \(address.labelWithTag)."
            : "Couldn't connect to \(address.labelWithTag)."
        if deviceHasOtherAddresses {
            text += " To use another address, choose it from the Connect menu."
        }
        if case KVMError.connectionFailed = error {
            return text
        }
        return text + "\n\n" + String(describing: error)
    }
}
