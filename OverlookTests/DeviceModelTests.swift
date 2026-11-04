import Foundation
import Testing
@testable import Overlook

@MainActor
@Suite("Device model")
struct DeviceModelTests {
    @Test(arguments: [
        (443, "https", "wss"),
        (8443, "https", "wss"),
        (80, "http", "ws"),
        (8080, "http", "ws"),
    ])
    func schemesFollowThePort(port: Int, http: String, webSocket: String) {
        let device = Fixtures.device(host: "kvm.example", port: port)
        #expect(device.httpScheme == http)
        #expect(device.webSocketScheme == webSocket)
        #expect(device.originURL == "\(http)://kvm.example:\(port)")
        #expect(device.webRTCURL == "\(webSocket)://kvm.example:\(port)/janus/ws")
        #expect(device.connectionString == "kvm.example:\(port)")
    }

    @Test func devicesAreEqualByIDAlone() {
        let a = Fixtures.device(id: "same", name: "A", host: "192.0.2.1")
        let b = Fixtures.device(id: "same", name: "B", host: "192.0.2.2")
        let c = Fixtures.device(id: "other", name: "A", host: "192.0.2.1")
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }

    @Test func storedRawValuesAreStable() {
        // These strings are in operators' saved-device records; renaming a case must not change them.
        #expect(KVMDeviceType.allCases.map(\.rawValue) == ["glinet_comet", "generic", "tailscale", "custom"])
        #expect(KVMCapability.allCases.map(\.rawValue) == [
            "video_streaming", "keyboard_input", "mouse_input",
            "virtual_media", "power_management", "ocr_support",
        ])
    }

    @Test func certificateChangeMessageNamesTheDeviceAndFingerprint() {
        let error = KVMError.certificateChanged(host: "192.0.2.1", port: 443, fingerprint: "abcd")
        let text = error.errorDescription ?? ""
        #expect(text.contains("192.0.2.1:443"))
        #expect(text.contains("AB:CD"))
        #expect(error.description == text)
    }

    // MARK: - What counts as the device refusing credentials

    @Test(arguments: [401, 403, 200, 204])
    func httpRejectionsAreAuthRejections(status: Int) {
        let error = GLKVMClient.ClientError.httpError(statusCode: status, body: nil)
        #expect(KVMDeviceManager.isAuthRejection(error))
    }

    @Test(arguments: [400, 404, 500, 502])
    func otherHTTPFailuresAreNot(status: Int) {
        let error = GLKVMClient.ClientError.httpError(statusCode: status, body: nil)
        #expect(KVMDeviceManager.isAuthRejection(error) == false)
    }

    @Test func transportFailuresAreNot() {
        #expect(KVMDeviceManager.isAuthRejection(URLError(.timedOut)) == false)
        #expect(KVMDeviceManager.isAuthRejection(KVMError.connectionFailed) == false)
        #expect(KVMDeviceManager.isAuthRejection(GLKVMClient.ClientError.decodingFailed) == false)
    }

    // MARK: - Keys the secrets are stored under

    @Test func secretAndPinKeysIgnoreHostCase() {
        #expect(KeychainTokenStore.account(host: "KVM.Example", port: 443) == "kvm.example:443")
        #expect(DeviceTrustStore.key(host: "KVM.Example", port: 8443) == "kvm.example:8443")
    }

    @Test func fingerprintsDisplayAsColonSeparatedPairs() {
        #expect(DeviceTrustStore.display("0a1b2c") == "0A:1B:2C")
        #expect(DeviceTrustStore.display("") == "")
    }
}
