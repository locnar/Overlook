import Foundation
import Security
import CryptoKit

/// Trust-on-first-use certificate pinning for KVM devices.
///
/// KVM devices ship self-signed certificates, so normal trust evaluation fails for them. Rather than
/// accept any certificate — which lets anyone on the network path read the auth token and the input
/// stream — the first certificate seen for a host:port is recorded, and every later connection must
/// present the same one. A certificate that passes normal system trust evaluation (a CA-issued one,
/// or one whose CA you installed) is accepted without pinning.
final class DeviceTrustStore {
    static let shared = DeviceTrustStore()

    enum Decision {
        case systemTrusted
        case pinnedMatch
        case pinnedOnFirstUse(fingerprint: String)
        case mismatch(expected: String, actual: String)
        case noCertificate
    }

    struct Mismatch: Equatable {
        let host: String
        let port: Int
        let expected: String
        let actual: String
    }

    private static let defaultsKey = "overlook.trusted_certificates.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var pins: [String: String]
    private var mismatches: [String: Mismatch] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pins = (defaults.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
    }

    static func key(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    /// Lowercase hex SHA-256 of the pinned leaf certificate, if one is recorded.
    func pinnedFingerprint(host: String, port: Int) -> String? {
        lock.withLock { pins[Self.key(host: host, port: port)] }
    }

    /// The mismatch recorded by the most recent failed evaluation for this host:port, if any.
    func pendingMismatch(host: String, port: Int) -> Mismatch? {
        lock.withLock { mismatches[Self.key(host: host, port: port)] }
    }

    /// Clears a recorded mismatch without touching the pin. Call before a connection attempt so a
    /// stale record from an earlier attempt is not misreported.
    func clearMismatch(host: String, port: Int) {
        let key = Self.key(host: host, port: port)
        lock.withLock { _ = mismatches.removeValue(forKey: key) }
    }

    /// Forgets the pin so the next connection re-pins whatever certificate it sees.
    func reset(host: String, port: Int) {
        let key = Self.key(host: host, port: port)
        lock.withLock {
            pins.removeValue(forKey: key)
            mismatches.removeValue(forKey: key)
            persistLocked()
        }
    }

    func evaluate(_ trust: SecTrust, host: String, port: Int) -> Decision {
        if SecTrustEvaluateWithError(trust, nil) {
            return .systemTrusted
        }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return .noCertificate
        }
        let actual = Self.fingerprint(of: leaf)
        let key = Self.key(host: host, port: port)

        return lock.withLock { () -> Decision in
            if let expected = pins[key] {
                if expected == actual {
                    mismatches.removeValue(forKey: key)
                    return .pinnedMatch
                }
                mismatches[key] = Mismatch(host: host, port: port, expected: expected, actual: actual)
                return .mismatch(expected: expected, actual: actual)
            }
            pins[key] = actual
            mismatches.removeValue(forKey: key)
            persistLocked()
            print("Pinned certificate for \(key): \(Self.display(actual))")
            return .pinnedOnFirstUse(fingerprint: actual)
        }
    }

    /// Resolves a URLSession challenge under this store's policy. Challenges that are not
    /// server-trust challenges get default handling.
    func resolve(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        switch evaluate(trust, host: space.host, port: space.port) {
        case .systemTrusted, .pinnedMatch, .pinnedOnFirstUse:
            return (.useCredential, URLCredential(trust: trust))
        case .mismatch, .noCertificate:
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    static func fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// "AB:CD:…" form for showing a fingerprint to the user.
    static func display(_ fingerprint: String) -> String {
        var pairs: [String] = []
        var remainder = Substring(fingerprint.uppercased())
        while !remainder.isEmpty {
            pairs.append(String(remainder.prefix(2)))
            remainder = remainder.dropFirst(2)
        }
        return pairs.joined(separator: ":")
    }

    private func persistLocked() {
        defaults.set(pins, forKey: Self.defaultsKey)
    }
}

/// URLSession delegate that applies `DeviceTrustStore` to server-trust challenges.
final class DeviceTrustSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = DeviceTrustStore.shared.resolve(challenge)
        completionHandler(disposition, credential)
    }
}
