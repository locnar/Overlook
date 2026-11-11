import Foundation
import Network
import Combine

/// One console's connection to one device: which device it is talking to, the HTTP client for it,
/// and the connect and disconnect steps.
///
/// This used to live on `KVMDeviceManager`, which still keeps the list of devices the app knows
/// about. That list is the app's; a connection is a console's. A connect still goes through the
/// catalog, because a device that connects is saved there with its new token.
@MainActor
final class SessionConnection: ObservableObject {
    @Published var connectedDevice: KVMDevice?
    @Published var glkvmClient: GLKVMClient?

    private let catalog: KVMDeviceManager
    /// The session's log, handed to the HTTP client so a certificate pinned while signing in is
    /// logged against this session's device. Nil for a connection no session owns.
    private let log: SessionLog?
    /// Whether the device accepts a TCP connection before anything is asked of it.
    private let reach: (KVMDevice) async -> Bool
    /// The HTTP client a connect signs in with.
    private let makeClient: (KVMDevice, SessionLog?) throws -> GLKVMClient
    private var cancellables = Set<AnyCancellable>()

    /// The catalog's certificate pins, as its credential store is the catalog's: the app's
    /// `DeviceTrustStore.shared`, and a scratch store under a test.
    private var trustStore: DeviceTrustStore { catalog.trustStore }

    /// `reach` and `makeClient` are for tests, which answer the TCP check themselves and hand
    /// back a client whose requests a stub answers. The app passes neither; its client pins
    /// certificates in the catalog's trust store.
    init(
        catalog: KVMDeviceManager,
        log: SessionLog? = nil,
        reach: @escaping (KVMDevice) async -> Bool = { await SessionConnection.isReachable($0) },
        makeClient: ((KVMDevice, SessionLog?) throws -> GLKVMClient)? = nil
    ) {
        self.catalog = catalog
        self.log = log
        self.reach = reach
        let trustStore = catalog.trustStore
        self.makeClient = makeClient ?? { try GLKVMClient(device: $0, log: $1, trustStore: trustStore) }

        // What is cleared matches what the catalog cleared when it held the connection itself:
        // removing an entry drops only the device, forgetting an address drops the client too.
        catalog.deviceRemovals
            .sink { [weak self] removal in
                guard let self else { return }
                switch removal {
                case .removed(let id):
                    if self.connectedDevice?.id == id {
                        self.connectedDevice = nil
                    }
                case .forgotten(let id, let addresses):
                    if let connected = self.connectedDevice,
                       connected.id == id || addresses.contains(connected.address) {
                        self.connectedDevice = nil
                        self.glkvmClient = nil
                    }
                }
            }
            .store(in: &cancellables)

        // A rename, a changed address list, or this entry becoming part of another device: take
        // the new details and stay connected through the same address.
        catalog.deviceUpdates
            .sink { [weak self] update in
                guard let self, let connected = self.connectedDevice, update.applies(to: connected) else { return }
                self.connectedDevice = update.applied(to: connected)
            }
            .store(in: &cancellables)
    }

    @discardableResult
    func connectToDevice(
        _ device: KVMDevice,
        authToken: String? = nil,
        password: String? = nil,
        user: String = "admin",
        savePassword: Bool = false
    ) async throws -> KVMDevice {
        // Validate device connection
        guard await reach(device) else {
            throw KVMError.connectionFailed
        }
        
        // Update device auth token if provided
        var finalDevice: KVMDevice
        if let token = authToken {
            var updatedDevice = device
            updatedDevice.authToken = token

            // Update in available devices
            catalog.updateDevice(updatedDevice)

            finalDevice = updatedDevice
        } else {
            finalDevice = device
        }

        guard let client = try? makeClient(finalDevice, log) else {
            throw KVMError.connectionFailed
        }

        trustStore.clearMismatch(host: finalDevice.host, port: finalDevice.port)

        do {
            try await client.authCheck()
        } catch {
            if let mismatch = trustStore.pendingMismatch(host: finalDevice.host, port: finalDevice.port) {
                throw KVMError.certificateChanged(host: mismatch.host, port: mismatch.port, fingerprint: mismatch.actual)
            }
            // Only a genuine rejection from the device means the token is missing or expired.
            // Network and transport failures must not turn into a password prompt.
            guard Self.isAuthRejection(error) else {
                throw error
            }

            // A password typed for this attempt wins; otherwise fall back to one saved for the
            // device, so an expired token logs back in without a prompt.
            let provided = (password?.isEmpty == false) ? password : nil
            // A password belongs to the device, so one saved under any of its addresses will do.
            let saved = provided == nil ? catalog.savedPassword(for: finalDevice) : nil
            guard let candidate = provided ?? saved?.password else {
                throw KVMError.authenticationFailed
            }

            do {
                let token = try await client.authLogin(user: user, password: candidate)
                client.authToken = token

                // Through the catalog's credential store: the login keychain in the app, under
                // the same service and account as always, and memory under the test host.
                if provided != nil, savePassword {
                    catalog.credentials.setPassword(candidate, host: finalDevice.host, port: finalDevice.port)
                }

                var updated = finalDevice
                updated.authToken = token
                catalog.updateDevice(updated)
                finalDevice = updated
            } catch {
                // A wrong password is an auth rejection and re-prompts; anything else is a
                // transport problem and the password may be fine.
                guard Self.isAuthRejection(error) else {
                    throw error
                }
                if let saved {
                    // Stale saved password: drop it so the operator is re-prompted rather than
                    // looping on it.
                    catalog.credentials.deletePassword(host: saved.address.host, port: saved.address.port)
                }
                throw KVMError.authenticationFailed
            }
        }

        let persisted = catalog.persistDevice(finalDevice)
        connectedDevice = persisted
        glkvmClient = client
        return persisted
    }

    /// True only when the device itself rejected the credentials or token: an HTTP 401/403, or an
    /// application-level `ok=false` on a 2xx response (how the GL.iNet login endpoint reports a
    /// wrong password). URL/network errors and 5xx responses are not auth rejections.
    static func isAuthRejection(_ error: Error) -> Bool {
        if case GLKVMClient.ClientError.httpError(let statusCode, _) = error {
            return statusCode == 401 || statusCode == 403 || (200...299).contains(statusCode)
        }
        return false
    }

    /// Whether `device` accepts a TCP connection within 5 seconds.
    nonisolated static func isReachable(_ device: KVMDevice) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: UInt16(device.port)) else {
            return false
        }

        final class Flag {
            var value: Bool = false
        }

        let queue = DispatchQueue(label: "com.overlook.validate")
        let connection = NWConnection(host: NWEndpoint.Host(device.host), port: port, using: .tcp)

        return await withCheckedContinuation { continuation in
            let finished = Flag()

            let timeoutWorkItem = DispatchWorkItem {
                if finished.value { return }
                finished.value = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: false)
            }

            queue.asyncAfter(deadline: .now() + 5, execute: timeoutWorkItem)

            connection.stateUpdateHandler = { (state: NWConnection.State) in
                switch state {
                case .ready:
                    if finished.value { return }
                    finished.value = true
                    timeoutWorkItem.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    if finished.value { return }
                    finished.value = true
                    timeoutWorkItem.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }
    
    func disconnectFromDevice() {
        connectedDevice = nil
        glkvmClient = nil
    }
}
