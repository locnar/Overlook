import Foundation

typealias GLKVMJSONObject = [String: JSONValue]

struct GLKVMResponse<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result
}

struct GLKVMEmptyResult: Decodable {}

struct GLKVMInitStatus: Decodable {
    let countryCode: String
    let isInited: Bool

    enum CodingKeys: String, CodingKey {
        case countryCode = "country_code"
        case isInited = "is_inited"
    }
}

struct GLKVMSystemGetConfigResult: Decodable {
    let config: GLKVMSystemConfig
}

/// The same answer, with the config kept as the JSON the device holds: every key, not only the
/// ones `GLKVMSystemConfig` models.
struct GLKVMSystemGetConfigObjectResult: Decodable {
    let config: GLKVMJSONObject
}

struct GLKVMSystemConfigShortcut: Codable, Hashable {
    let keys: [String]
    let label: String
}

struct GLKVMSystemConfig: Codable, Hashable {
    var shortcuts: [GLKVMSystemConfigShortcut]
    var orientation: Int
    /// Nil when the device has no `stream_quality` or holds something other than a whole number.
    /// It is then left out of the JSON this model writes, so a settings write keeps the device's
    /// own value until the operator picks a Quality preset.
    var streamQuality: Int?
    var videoMode: String
    var showCursor: Bool
    var mousePolling: Int
    var mouseControl: Bool
    var relativeSense: Int
    var scrollRate: Int
    var reverseScrolling: String
    var keyboardControl: Bool
    var themeMode: String
    var mouseJiggle: Bool
    var keymap: String
    var gotMutedPanelTip: Bool
    var isAbsoluteMouse: Bool
    var fingerbotStrength: Int
    var videoProcessing: String

    enum CodingKeys: String, CodingKey {
        case shortcuts
        case orientation
        case streamQuality = "stream_quality"
        case videoMode = "video_mode"
        case showCursor = "show_cursor"
        case mousePolling = "mouse_polling"
        case mouseControl = "mouse_control"
        case relativeSense = "relative_sense"
        case scrollRate = "scroll_rate"
        case reverseScrolling = "reverse_scrolling"
        case keyboardControl = "keyboard_control"
        case themeMode = "theme_mode"
        case mouseJiggle = "mouse_jiggle"
        case keymap
        case gotMutedPanelTip = "got_muted_panel_tip"
        case isAbsoluteMouse = "is_absolute_mouse"
        case fingerbotStrength = "fingerbot_strength"
        case videoProcessing = "video_processing"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcuts = (try? container.decode([GLKVMSystemConfigShortcut].self, forKey: .shortcuts)) ?? []
        orientation = (try? container.decode(Int.self, forKey: .orientation)) ?? 0
        streamQuality = try? container.decode(Int.self, forKey: .streamQuality)
        videoMode = (try? container.decode(String.self, forKey: .videoMode)) ?? ""
        showCursor = (try? container.decode(Bool.self, forKey: .showCursor)) ?? true
        mousePolling = (try? container.decode(Int.self, forKey: .mousePolling)) ?? 10
        mouseControl = (try? container.decode(Bool.self, forKey: .mouseControl)) ?? true
        relativeSense = (try? container.decode(Int.self, forKey: .relativeSense)) ?? 10
        scrollRate = (try? container.decode(Int.self, forKey: .scrollRate)) ?? 5
        reverseScrolling = (try? container.decode(String.self, forKey: .reverseScrolling)) ?? "STANDARD"
        keyboardControl = (try? container.decode(Bool.self, forKey: .keyboardControl)) ?? true
        themeMode = (try? container.decode(String.self, forKey: .themeMode)) ?? "auto"
        mouseJiggle = (try? container.decode(Bool.self, forKey: .mouseJiggle)) ?? false
        keymap = (try? container.decode(String.self, forKey: .keymap)) ?? "en-us"
        gotMutedPanelTip = (try? container.decode(Bool.self, forKey: .gotMutedPanelTip)) ?? false
        isAbsoluteMouse = (try? container.decode(Bool.self, forKey: .isAbsoluteMouse)) ?? true
        fingerbotStrength = (try? container.decode(Int.self, forKey: .fingerbotStrength)) ?? 0
        videoProcessing = (try? container.decode(String.self, forKey: .videoProcessing)) ?? ""
    }
}

extension GLKVMSystemConfig {
    /// The modeled keys, as the JSON they are written as.
    func jsonObject() throws -> GLKVMJSONObject {
        try JSONDecoder().decode(GLKVMJSONObject.self, from: JSONEncoder().encode(self))
    }

    /// The keys whose value differs from `previous`, with their new values. This is what a
    /// settings change asks the device to write. A key the decoder filled with a default because
    /// the device did not have it is not written unless it was changed, so a default never
    /// replaces a value the device holds in a form this model does not read.
    func changes(from previous: GLKVMSystemConfig) -> GLKVMJSONObject {
        guard let next = try? jsonObject(), let before = try? previous.jsonObject() else { return [:] }
        return next.filter { before[$0.key] != $0.value }
    }
}

// MARK: - Video mode

/// The KVM's video mode: `video_mode` in its system config on firmware 1.10.0 and later, one of
/// `webrtc`, `gl_webrtc`, `direct_h264` or `flex_fec` (the default). Overlook's stream goes through
/// Janus, which the device stops in `gl_webrtc` ("WebRTC (Native)"); that one mode cannot work.
/// Overlook only reads the mode; changing it is the operator's, in the KVM's web page.
enum GLKVMVideoMode {
    static let nativeWebRTC = "gl_webrtc"

    /// Reads the device's `video_mode`; nil when it cannot be read.
    typealias Reader = @MainActor () async -> String?

    static func blocksStream(_ mode: String?) -> Bool {
        mode == nativeWebRTC
    }

    /// The error to report for a stream connect that failed with `error` at the Janus stage: the
    /// video-mode error when the device turns out to be in WebRTC (Native) mode, `error` itself
    /// otherwise (any other mode, no mode, or a config that could not be read). `mode` is what
    /// was read, for the caller to keep.
    @MainActor
    static func explain(_ error: Error, readMode: Reader?) async -> (error: Error, mode: String?) {
        guard let readMode else { return (error, nil) }
        let mode = await readMode()
        return (blocksStream(mode) ? NativeWebRTCVideoModeError() : error, mode)
    }
}

/// The stream cannot come up because the KVM is in the WebRTC (Native) video mode.
struct NativeWebRTCVideoModeError: LocalizedError, CustomStringConvertible, Equatable {
    static let message = "This KVM is set to the WebRTC (Native) video mode, which Overlook can't use. "
        + "In the KVM's web page, change Video › Mode to another mode, then connect again."

    var errorDescription: String? { Self.message }
    var description: String { Self.message }
}

extension GLKVMClient {
    /// The device's `video_mode`, read fresh; nil when it cannot be read.
    func readVideoMode() async -> String? {
        try? await getSystemConfig().videoMode
    }
}

struct GLKVMTurnCredentials: Decodable {
    let password: String
    let ttl: Int
    let uris: [String]
    let username: String
}

struct GLKVMHidKeymapsState: Decodable, Hashable {
    struct Keymaps: Decodable, Hashable {
        let `default`: String
        let available: [String]
    }

    let keymaps: Keymaps
}

/// The device's mouse jiggler, from the `jiggler` object of kvmd's HID state (`GET /api/hid`,
/// and every `hid` event on the HID socket).
struct GLKVMJigglerState: Equatable {
    /// Whether this device has the jiggler at all (kvmd's `jiggler.enabled` option). When it is
    /// false, kvmd ignores requests to switch it.
    let isAvailable: Bool
    /// Whether it is moving the mouse now: switched on, or inside a scheduled period.
    let isActive: Bool
    /// Seconds without input before it moves the mouse.
    let interval: Int?

    init(isAvailable: Bool, isActive: Bool, interval: Int? = nil) {
        self.isAvailable = isAvailable
        self.isActive = isActive
        self.interval = interval
    }

    /// Nil when the state has no jiggler object, as a partial `hid` event may not.
    init?(hidState: JSONValue?) {
        guard let jiggler = hidState?["jiggler"],
              let enabled = jiggler["enabled"]?.boolValue,
              let active = jiggler["active"]?.boolValue else { return nil }
        self.init(isAvailable: enabled, isActive: active, interval: jiggler["interval"]?.intValue)
    }
}

struct GLKVMStreamerState: Decodable, Hashable {
    struct Features: Decodable, Hashable {
        let quality: Bool
        let resolution: Bool
        let h264: Bool
        let zeroDelay: Bool

        enum CodingKeys: String, CodingKey {
            case quality
            case resolution
            case h264
            case zeroDelay = "zero_delay"
        }
    }

    struct Limits: Decodable, Hashable {
        struct MinMax: Decodable, Hashable {
            let min: Int
            let max: Int
        }

        let desiredFps: MinMax
        let h264Bitrate: MinMax
        let h264Gop: MinMax

        enum CodingKeys: String, CodingKey {
            case desiredFps = "desired_fps"
            case h264Bitrate = "h264_bitrate"
            case h264Gop = "h264_gop"
        }
    }

    struct Params: Decodable, Hashable {
        let desiredFps: Int?
        let quality: Int?
        let h264Bitrate: Int?
        let h264Gop: Int?
        let zeroDelay: Bool?
        let resolution: String?

        enum CodingKeys: String, CodingKey {
            case desiredFps = "desired_fps"
            case quality
            case h264Bitrate = "h264_bitrate"
            case h264Gop = "h264_gop"
            case zeroDelay = "zero_delay"
            case resolution
        }
    }

    let features: Features?
    let limits: Limits?
    let params: Params?
}

struct GLKVMMSDPartitionDevice: Decodable, Hashable {
    let path: String
    let size: Int
    let uuid: String
    let filesystem: String
    let label: String
    let isCurrent: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case size
        case uuid
        case filesystem
        case label
        case isCurrent = "is_current"
    }
}

struct GLKVMMSDPartitionShowResult: Decodable, Hashable {
    let devices: [String: GLKVMMSDPartitionDevice]
}

struct GLKVMMSDWriteImageInfo: Decodable, Hashable {
    let name: String
    let size: Int
    let written: Int
}

struct GLKVMMSDWriteResult: Decodable, Hashable {
    let image: GLKVMMSDWriteImageInfo
}

struct GLKVMWebSocketEvent: Decodable, Hashable {
    let eventType: String
    let event: JSONValue?
    /// For a `pong`: the time since the ping it answers, measured by the socket that sent it.
    var roundTripMs: Int? = nil

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case event
    }
}

struct GLKVMWebSocketSend: Encodable {
    let eventType: String
    let event: JSONValue

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case event
    }
}

struct GLKVMAuthLoginResult: Decodable {
    let token: String?

    enum CodingKeys: String, CodingKey {
        case token
        case authToken = "auth_token"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decodeIfPresent(String.self, forKey: .token)
            ?? container.decodeIfPresent(String.self, forKey: .authToken)
    }
}

/// The URLSession a `GLKVMClient` and its HID sockets share, invalidated when the last of them
/// lets go of it.
///
/// A URLSession made with a delegate keeps itself and that delegate alive until it is invalidated,
/// so a client that simply went away left both behind: one per connect. Invalidating when the
/// owner disconnects would be too early, since the hang-up and the release of held keys are still
/// going out over this session as the session disconnects or quits. Tying it to the last user
/// covers every way a client is let go of: a request in flight holds its client, and an open
/// socket's receive loop holds its `WebSocketClient` until the socket is closed.
final class GLKVMURLSession: Sendable {
    let session: URLSession

    init(_ session: URLSession) {
        self.session = session
    }

    deinit {
        // Nothing can be using the session by now, so there should be nothing left to finish;
        // finishing rather than cancelling still lets a socket's closing frame go out.
        session.finishTasksAndInvalidate()
    }
}

/// Lets one caller through at a time, in the order they arrived. It is a lock for async work that
/// awaits in the middle, such as a read followed by a write that depends on it.
actor AsyncSerialGate {
    private var isHeld = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the gate to the next caller in line, or opens it when nobody is waiting.
    func leave() {
        if waiting.isEmpty {
            isHeld = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

final class GLKVMClient {
    enum ClientError: Error {
        case invalidBaseURL
        case invalidURL
        case httpError(statusCode: Int, body: String?)
        case decodingFailed
    }

    let baseURL: URL
    var authToken: String?

    /// Shared with every socket made from this client, which keeps it alive after the client.
    /// Not private so tests can check it is released.
    let urlSession: GLKVMURLSession
    private var session: URLSession { urlSession.session }

    /// The URLSession for `hid/print` alone, with long timeouts. The device answers a print only
    /// once it has typed the text, and it stops typing when the request's connection closes, so
    /// the ordinary 15 s / 30 s limits cut a long paste off partway. Kept apart so every other
    /// request still gives up at the ordinary limits. Held and invalidated the same way as
    /// `urlSession`, and released with the client (no socket uses it). Not private so tests can
    /// check that.
    let printURLSession: GLKVMURLSession

    /// Deadlines for the HID sockets made from this client. Tests shorten them.
    var hidSocketTiming = WebSocketClient.Timing.standard
    /// Makes the socket under each HID client made from this one; nil for a URLSession WebSocket
    /// task on `urlSession`. Tests set it to stand in for the device's socket.
    var makeHIDSocket: (@Sendable (URLRequest) -> HIDSocket)?

    /// The session's log: certificate pinning while this client signs in, settings writes, and
    /// the HID sockets' timeouts.
    private let log: SessionLog?
    /// Settings writes take turns; see `updateSystemConfig`.
    private let configWriteGate = AsyncSerialGate()

    /// `log` is the session's, for certificate pinning and for settings writes.
    /// `sessionConfiguration` is the starting point for this client's URLSession. Tests pass one
    /// whose protocol classes answer in place of a device, so no request reaches the network.
    /// `trustStore` holds the certificate pins; a connection passes its catalog's.
    init(
        host: String,
        port: Int = 443,
        authToken: String? = nil,
        log: SessionLog? = nil,
        sessionConfiguration: URLSessionConfiguration = .default,
        trustStore: DeviceTrustStore = .shared
    ) throws {
        let scheme = Self.defaultHTTPScheme(for: port)
        guard let url = URL(string: "\(scheme)://\(host):\(port)") else {
            throw ClientError.invalidBaseURL
        }

        self.baseURL = url
        self.authToken = authToken
        self.log = log

        let config = (sessionConfiguration.copy() as? URLSessionConfiguration) ?? .default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30

        // Self-signed device certificates are pinned on first use; see DeviceTrustStore.
        self.urlSession = GLKVMURLSession(
            URLSession(configuration: config, delegate: DeviceTrustSessionDelegate(trustStore: trustStore, log: log), delegateQueue: nil)
        )

        // A print request sends nothing back until the text is typed, so the request timeout,
        // which counts time without data, bounds how long one part of a paste may take to type.
        // RemotePasteQueue keeps each part to seconds of typing, not minutes; these leave a wide
        // margin.
        let printConfig = (config.copy() as? URLSessionConfiguration) ?? config
        printConfig.timeoutIntervalForRequest = Self.printRequestTimeout
        printConfig.timeoutIntervalForResource = Self.printResourceTimeout
        self.printURLSession = GLKVMURLSession(
            URLSession(configuration: printConfig, delegate: DeviceTrustSessionDelegate(trustStore: trustStore, log: log), delegateQueue: nil)
        )
    }

    static let printRequestTimeout: TimeInterval = 120
    static let printResourceTimeout: TimeInterval = 300

    static func defaultHTTPScheme(for port: Int) -> String {
        switch port {
        case 80, 8080:
            return "http"
        default:
            return "https"
        }
    }

    static func defaultWebSocketScheme(for port: Int) -> String {
        defaultHTTPScheme(for: port) == "https" ? "wss" : "ws"
    }

    convenience init(device: KVMDevice, log: SessionLog? = nil, trustStore: DeviceTrustStore = .shared) throws {
        try self.init(
            host: device.host,
            port: device.port,
            authToken: device.authToken.isEmpty ? nil : device.authToken,
            log: log,
            trustStore: trustStore
        )
    }

    private func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidURL
        }

        components.path = "/" + trimmed
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw ClientError.invalidURL
        }

        return url
    }

    private func request<Response: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        responseType: Response.Type,
        on sessionOverride: URLSession? = nil
    ) async throws -> Response {
        let url = try makeURL(path: path, queryItems: query)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        if let authToken, !authToken.isEmpty {
            request.setValue("auth_token=\(authToken)", forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await (sessionOverride ?? session).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.decodingFailed
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8)
            var errorMessage: String? = nil
            if let wrapped = try? JSONDecoder().decode(GLKVMResponse<GLKVMJSONObject>.self, from: data) {
                if case .string(let s) = wrapped.result["error_msg"] {
                    errorMessage = s
                } else if case .string(let s) = wrapped.result["message"] {
                    errorMessage = s
                }
            }
            throw ClientError.httpError(statusCode: http.statusCode, body: errorMessage ?? bodyString)
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary \(data.count)B>"
            NSLog("[Overlook glkvm] decode failed for %@ (status=%d): %@ | body: %@", url.absoluteString, http.statusCode, "\(error)", preview)
            throw ClientError.decodingFailed
        }
    }

    func isInited() async throws -> GLKVMInitStatus {
        let response = try await request(
            method: "GET",
            path: "api/init/is_inited",
            responseType: GLKVMResponse<GLKVMInitStatus>.self
        )

        return response.result
    }

    func authCheck() async throws {
        _ = try await request(
            method: "GET",
            path: "api/auth/check",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func authLogin(user: String = "admin", password: String) async throws -> String {
        let boundary = "----OverlookBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"user\"\r\n\r\n".data(using: .utf8) ?? Data())
        body.append("\(user)\r\n".data(using: .utf8) ?? Data())
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"passwd\"\r\n\r\n".data(using: .utf8) ?? Data())
        body.append("\(password)\r\n".data(using: .utf8) ?? Data())
        body.append("--\(boundary)--\r\n".data(using: .utf8) ?? Data())

        let url = try makeURL(path: "api/auth/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.decodingFailed
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8)
            throw ClientError.httpError(statusCode: http.statusCode, body: bodyString)
        }

        if let wrapped = try? JSONDecoder().decode(GLKVMResponse<GLKVMAuthLoginResult>.self, from: data) {
            if let token = wrapped.result.token, !token.isEmpty {
                return token
            }
            if wrapped.ok == false {
                let bodyString = String(data: data, encoding: .utf8)
                throw ClientError.httpError(statusCode: http.statusCode, body: bodyString)
            }
        }

        if let token = authTokenFromSetCookieHeaders(in: http, for: url) {
            return token
        }

        let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary \(data.count)B>"
        NSLog("[Overlook glkvm] login succeeded but no auth token was found. body: %@", preview)
        throw ClientError.decodingFailed
    }

    func getSystemConfig() async throws -> GLKVMSystemConfig {
        let response = try await request(
            method: "GET",
            path: "api/system/get_config",
            responseType: GLKVMResponse<GLKVMSystemGetConfigResult>.self
        )

        return response.result.config
    }

    func getSystemConfigObject() async throws -> GLKVMJSONObject {
        let response = try await request(
            method: "GET",
            path: "api/system/get_config",
            responseType: GLKVMResponse<GLKVMSystemGetConfigObjectResult>.self
        )

        return response.result.config
    }

    /// Writes `changes` into the device's user config and returns the config as written.
    ///
    /// `set_config` replaces the whole config file with the request body. Sending only the keys
    /// Overlook models therefore erased every other key: the ones the device's web UI keeps for
    /// itself and the ones newer firmware adds. So each write reads the config as the device
    /// holds it at that moment, puts the changed keys over it, and sends the whole object back.
    /// Keys Overlook does not know keep their value and their JSON type.
    ///
    /// Writes from one client take turns. Two that overlapped would read the same config, and
    /// the second would put back the value the first had just changed.
    func updateSystemConfig(_ changes: GLKVMJSONObject) async throws -> GLKVMSystemConfig {
        await configWriteGate.enter()
        do {
            let written = try await mergeIntoSystemConfig(changes)
            await configWriteGate.leave()
            return written
        } catch {
            await configWriteGate.leave()
            throw error
        }
    }

    private func mergeIntoSystemConfig(_ changes: GLKVMJSONObject) async throws -> GLKVMSystemConfig {
        // Read fresh every time: a copy kept from earlier would undo changes made since, in the
        // web UI or by firmware.
        let current = try await getSystemConfigObject()
        let merged = current.merging(changes) { _, changed in changed }
        let kept = current.keys.filter { changes[$0] == nil }.sorted()
        log?.debug(.device, "Settings write: \(changes.keys.sorted().joined(separator: ", ")); kept \(kept.count) other keys: \(kept.joined(separator: ", "))")

        let response = try await request(
            method: "POST",
            path: "api/system/set_config",
            body: try JSONEncoder().encode(merged),
            contentType: "application/json",
            responseType: GLKVMResponse<GLKVMSystemGetConfigResult>.self
        )

        return response.result.config
    }

    func getStreamerState() async throws -> GLKVMStreamerState {
        let response = try await request(
            method: "GET",
            path: "api/streamer",
            responseType: GLKVMResponse<GLKVMStreamerState>.self
        )
        return response.result
    }

    func setStreamerParams(_ params: [String: String]) async throws {
        let queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        _ = try await request(
            method: "POST",
            path: "api/streamer/set_params",
            query: queryItems,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func setHIDParams(_ params: [String: String]) async throws {
        let queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        _ = try await request(
            method: "POST",
            path: "api/hid/set_params",
            query: queryItems,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func getTurnCredentials() async throws -> GLKVMTurnCredentials {
        let response = try await request(
            method: "GET",
            path: "api/turn/get_turn",
            responseType: GLKVMResponse<GLKVMTurnCredentials>.self
        )

        return response.result
    }

    func websocketURL() throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidURL
        }
        components.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        components.path = "/api/ws"
        guard let url = components.url else {
            throw ClientError.invalidURL
        }
        return url
    }

    func mediaWebsocketURL() throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidURL
        }
        components.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        components.path = "/api/media/ws"
        guard let url = components.url else {
            throw ClientError.invalidURL
        }
        return url
    }
}

private func authTokenFromSetCookieHeaders(in response: HTTPURLResponse, for url: URL) -> String? {
    var headerFields: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
        headerFields[String(describing: key)] = String(describing: value)
    }

    return HTTPCookie
        .cookies(withResponseHeaderFields: headerFields, for: url)
        .first(where: { $0.name == "auth_token" })?
        .value
}

extension GLKVMClient.ClientError: CustomStringConvertible {
    var description: String {
        switch self {
        case .invalidBaseURL:
            return "invalidBaseURL"
        case .invalidURL:
            return "invalidURL"
        case .decodingFailed:
            return "decodingFailed"
        case .httpError(let statusCode, let body):
            if let body, !body.isEmpty {
                return "httpError(\(statusCode)): \(body)"
            }
            return "httpError(\(statusCode))"
        }
    }
}

extension GLKVMClient {
    private func requestData(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        let url = try makeURL(path: path, queryItems: query)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        if let authToken, !authToken.isEmpty {
            request.setValue("auth_token=\(authToken)", forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.decodingFailed
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8)
            var errorMessage: String? = nil
            if let wrapped = try? JSONDecoder().decode(GLKVMResponse<GLKVMJSONObject>.self, from: data) {
                if case .string(let s) = wrapped.result["error_msg"] {
                    errorMessage = s
                } else if case .string(let s) = wrapped.result["message"] {
                    errorMessage = s
                }
            }
            throw ClientError.httpError(statusCode: http.statusCode, body: errorMessage ?? bodyString)
        }

        return data
    }
}

extension GLKVMClient {
    func getEDID() async throws -> String {
        let data = try await requestData(
            method: "GET",
            path: "api/upgrade/get_edid"
        )

        let decoder = JSONDecoder()

        if let wrapped = try? decoder.decode(GLKVMResponse<String>.self, from: data) {
            return wrapped.result
        }

        if let wrapped = try? decoder.decode(GLKVMResponse<GLKVMJSONObject>.self, from: data) {
            if case .string(let s) = wrapped.result["edid"] {
                return s
            }
            if case .string(let s) = wrapped.result["EDID"] {
                return s
            }
        }

        if let s = String(data: data, encoding: .utf8) {
            return s
        }

        throw ClientError.decodingFailed
    }

    func setEDID(_ edid: String) async throws {
        let boundary = "----geckoformboundary\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"edid\"\r\n\r\n".data(using: .utf8) ?? Data())
        body.append("\(edid)\r\n".data(using: .utf8) ?? Data())
        body.append("--\(boundary)--\r\n".data(using: .utf8) ?? Data())

        _ = try await requestData(
            method: "POST",
            path: "api/upgrade/edid",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }
}

extension GLKVMClient {
    func getHidState() async throws -> GLKVMJSONObject {
        let response = try await request(
            method: "GET",
            path: "api/hid",
            responseType: GLKVMResponse<GLKVMJSONObject>.self
        )
        return response.result
    }

    /// The jiggler as the device reports it; nil for firmware whose HID state has none.
    func getMouseJiggler() async throws -> GLKVMJigglerState? {
        GLKVMJigglerState(hidState: .object(try await getHidState()))
    }

    /// Switches the device's mouse jiggler. `hid/set_params?jiggler=` is the only switch kvmd
    /// has; the config's `mouse_jiggle` key is the web UI's record of its own toggle and moves
    /// nothing.
    func setMouseJiggler(_ on: Bool) async throws {
        try await setHIDParams(["jiggler": on ? "true" : "false"])
    }

    func setHidConnected(_ connected: Bool) async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/set_connected",
            query: [URLQueryItem(name: "connected", value: connected ? "true" : "false")],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func resetHid() async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/reset",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func getHidKeymaps() async throws -> GLKVMHidKeymapsState {
        let response = try await request(
            method: "GET",
            path: "api/hid/keymaps",
            responseType: GLKVMResponse<GLKVMHidKeymapsState>.self
        )
        return response.result
    }

    /// Types `text` on the target. kvmd cuts the text to `limit` code points, 1024 when no limit
    /// is given; 0 means no limit, so that is the default here. The request returns once the text
    /// has been typed, and goes over `printURLSession` so a long one is not timed out.
    func hidPrint(text: String, keymap: String? = nil, limit: Int = 0, slow: Bool? = nil) async throws {
        var query: [URLQueryItem] = []
        if let keymap {
            query.append(URLQueryItem(name: "keymap", value: keymap))
        }
        query.append(URLQueryItem(name: "limit", value: String(limit)))
        if let slow {
            query.append(URLQueryItem(name: "slow", value: slow ? "true" : "false"))
        }
        let body = text.data(using: .utf8) ?? Data()
        _ = try await request(
            method: "POST",
            path: "api/hid/print",
            query: query,
            body: body,
            contentType: "text/plain; charset=utf-8",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self,
            on: printURLSession.session
        )
    }

    func sendHidShortcut(keys: [String]) async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/events/send_shortcut",
            query: [URLQueryItem(name: "keys", value: keys.joined(separator: ","))],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func sendHidKey(key: String, state: Bool? = nil, finish: Bool? = nil) async throws {
        var query: [URLQueryItem] = [URLQueryItem(name: "key", value: key)]
        if let state {
            query.append(URLQueryItem(name: "state", value: state ? "true" : "false"))
        }
        if let finish {
            query.append(URLQueryItem(name: "finish", value: finish ? "true" : "false"))
        }
        _ = try await request(
            method: "POST",
            path: "api/hid/events/send_key",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func sendHidMouseButton(button: String, state: Bool? = nil) async throws {
        var query: [URLQueryItem] = [URLQueryItem(name: "button", value: button)]
        if let state {
            query.append(URLQueryItem(name: "state", value: state ? "true" : "false"))
        }
        _ = try await request(
            method: "POST",
            path: "api/hid/events/send_mouse_button",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func sendHidMouseMove(toX: Int, toY: Int) async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/events/send_mouse_move",
            query: [
                URLQueryItem(name: "to_x", value: String(toX)),
                URLQueryItem(name: "to_y", value: String(toY)),
            ],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func sendHidMouseRelative(deltaX: Int, deltaY: Int) async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/events/send_mouse_relative",
            query: [
                URLQueryItem(name: "delta_x", value: String(deltaX)),
                URLQueryItem(name: "delta_y", value: String(deltaY)),
            ],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }
}

extension GLKVMClient {
    func getMsdState() async throws -> GLKVMJSONObject {
        let response = try await request(
            method: "GET",
            path: "api/msd",
            responseType: GLKVMResponse<GLKVMJSONObject>.self
        )
        return response.result
    }

    func setMsdParams(image: String? = nil, cdrom: Bool? = nil, rw: Bool? = nil) async throws {
        var query: [URLQueryItem] = []
        if let image {
            query.append(URLQueryItem(name: "image", value: image))
        }
        if let cdrom {
            query.append(URLQueryItem(name: "cdrom", value: cdrom ? "true" : "false"))
        }
        if let rw {
            query.append(URLQueryItem(name: "rw", value: rw ? "true" : "false"))
        }
        _ = try await request(
            method: "POST",
            path: "api/msd/set_params",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func setMsdConnected(_ connected: Bool) async throws {
        _ = try await request(
            method: "POST",
            path: "api/msd/set_connected",
            query: [URLQueryItem(name: "connected", value: connected ? "true" : "false")],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func msdPartitionShow() async throws -> GLKVMMSDPartitionShowResult {
        let response = try await request(
            method: "GET",
            path: "api/msd/partition_show",
            responseType: GLKVMResponse<GLKVMMSDPartitionShowResult>.self
        )
        return response.result
    }

    func msdPartitionConnect() async throws {
        _ = try await request(
            method: "GET",
            path: "api/msd/partition_connect",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func msdPartitionDisconnect() async throws {
        _ = try await request(
            method: "GET",
            path: "api/msd/partition_disconnect",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func msdPartitionFormat(path: String) async throws {
        _ = try await request(
            method: "GET",
            path: "api/msd/partition_format",
            query: [URLQueryItem(name: "path", value: path)],
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func msdRead(image: String, compress: String? = nil) async throws -> Data {
        var query: [URLQueryItem] = [URLQueryItem(name: "image", value: image)]
        if let compress {
            query.append(URLQueryItem(name: "compress", value: compress))
        }
        return try await requestData(
            method: "GET",
            path: "api/msd/read",
            query: query
        )
    }

    func msdWrite(image: String, data: Data, prefix: String? = nil, removeIncomplete: Bool? = nil) async throws -> GLKVMMSDWriteResult {
        var query: [URLQueryItem] = [URLQueryItem(name: "image", value: image)]
        if let prefix {
            query.append(URLQueryItem(name: "prefix", value: prefix))
        }
        if let removeIncomplete {
            query.append(URLQueryItem(name: "remove_incomplete", value: removeIncomplete ? "true" : "false"))
        }
        let response = try await request(
            method: "POST",
            path: "api/msd/write",
            query: query,
            body: data,
            contentType: "application/octet-stream",
            responseType: GLKVMResponse<GLKVMMSDWriteResult>.self
        )
        return response.result
    }

    func msdWriteRemote(url: URL, image: String? = nil, prefix: String? = nil, insecure: Bool? = nil, timeout: Double? = nil, removeIncomplete: Bool? = nil) async throws -> [GLKVMMSDWriteResult] {
        var query: [URLQueryItem] = [URLQueryItem(name: "url", value: url.absoluteString)]
        if let image {
            query.append(URLQueryItem(name: "image", value: image))
        }
        if let prefix {
            query.append(URLQueryItem(name: "prefix", value: prefix))
        }
        if let insecure {
            query.append(URLQueryItem(name: "insecure", value: insecure ? "true" : "false"))
        }
        if let timeout {
            query.append(URLQueryItem(name: "timeout", value: String(timeout)))
        }
        if let removeIncomplete {
            query.append(URLQueryItem(name: "remove_incomplete", value: removeIncomplete ? "true" : "false"))
        }

        let data = try await requestData(
            method: "POST",
            path: "api/msd/write_remote",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded"
        )

        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline)
        let decoder = JSONDecoder()

        var results: [GLKVMMSDWriteResult] = []
        results.reserveCapacity(lines.count)

        for line in lines {
            let lineData = Data(line.utf8)
            if let wrapped = try? decoder.decode(GLKVMResponse<GLKVMMSDWriteResult>.self, from: lineData) {
                results.append(wrapped.result)
                continue
            }
            if let unwrapped = try? decoder.decode(GLKVMMSDWriteResult.self, from: lineData) {
                results.append(unwrapped)
                continue
            }
        }

        return results
    }

    func msdRemove(image: String) async throws {
        _ = try await request(
            method: "POST",
            path: "api/msd/remove",
            query: [URLQueryItem(name: "image", value: image)],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func msdReset() async throws {
        _ = try await request(
            method: "POST",
            path: "api/msd/reset",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }
}

extension GLKVMClient {
    enum AtxPowerAction: String {
        case on
        case off
        case offHard = "off_hard"
        case resetHard = "reset_hard"
    }

    enum AtxButton: String {
        case power
        case powerLong = "power_long"
        case reset
    }

    func getAtxState() async throws -> GLKVMJSONObject {
        let response = try await request(
            method: "GET",
            path: "api/atx",
            responseType: GLKVMResponse<GLKVMJSONObject>.self
        )
        return response.result
    }

    func atxPower(_ action: AtxPowerAction, wait: Bool? = nil) async throws {
        var query: [URLQueryItem] = [URLQueryItem(name: "action", value: action.rawValue)]
        if let wait {
            query.append(URLQueryItem(name: "wait", value: wait ? "true" : "false"))
        }
        _ = try await request(
            method: "POST",
            path: "api/atx/power",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func atxClick(_ button: AtxButton, wait: Bool? = nil) async throws {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "button", value: button.rawValue),
        ]
        if let wait {
            query.append(URLQueryItem(name: "wait", value: wait ? "true" : "false"))
        }
        _ = try await request(
            method: "POST",
            path: "api/atx/click",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }
}

extension GLKVMClient {
    func resetStreamer() async throws {
        _ = try await request(
            method: "POST",
            path: "api/streamer/reset",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }
}

/// The socket under a HID `WebSocketClient`: a `URLSessionWebSocketTask` in the app, and in tests a
/// stand-in that can hold a frame or leave a ping unanswered.
protocol HIDSocket: AnyObject, Sendable {
    func resume()
    /// Calls `completion` once: when the socket has taken the frame, or with the error that
    /// stopped it.
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping @Sendable (Error?) -> Void)
    func receive() async throws -> URLSessionWebSocketTask.Message
    /// Closes the socket with a close frame.
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    /// Drops the socket without waiting to say goodbye, for one that has stopped working.
    func abort()
}

/// A `URLSessionWebSocketTask` as a `HIDSocket`.
final class URLSessionHIDSocket: HIDSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(_ task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() {
        task.resume()
    }

    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping @Sendable (Error?) -> Void) {
        task.send(message) { error in completion(error) }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
    }

    func abort() {
        task.cancel()
    }
}

extension GLKVMClient {
    func makeWebSocketClient(stream: Bool = true) throws -> WebSocketClient {
        let url = try websocketURL()

        var request = URLRequest(url: url)
        if let authToken, !authToken.isEmpty {
            request.setValue("auth_token=\(authToken)", forHTTPHeaderField: "Cookie")
        }

        return WebSocketClient(
            session: urlSession,
            request: request,
            timing: hidSocketTiming,
            log: log,
            makeSocket: makeHIDSocket
        )
    }

    actor WebSocketClient {
        enum WebSocketError: LocalizedError {
            case notConnected
            case encodingFailed
            case decodingFailed
            /// The socket did not take a frame within its deadline, and has been closed.
            case sendTimedOut

            /// What a failed HID command's log line says.
            var errorDescription: String? {
                switch self {
                case .notConnected: return "the HID socket is not connected"
                case .encodingFailed: return "the frame could not be encoded"
                case .decodingFailed: return "the frame could not be decoded"
                case .sendTimedOut: return "the HID socket did not take the frame in time"
                }
            }
        }

        /// How long the socket may take over each thing before it is taken to be dead.
        struct Timing: Sendable {
            /// Between pings. kvmd answers each one with a pong.
            var pingInterval: Duration
            /// For the socket to take one frame once it is open.
            var sendTimeout: Duration
            /// For the socket to take a frame sent before it is known to be open, which waits for
            /// the handshake first.
            var openTimeout: Duration
            /// For a pong, counted from the oldest ping still waiting for one.
            var pongDeadline: Duration

            /// A frame is a few bytes, and an open socket takes it as soon as it is handed to the
            /// network stack: it waits only when the connection has stopped draining. A second is
            /// far past that and already too late for a keystroke, and every input queued behind
            /// it waits too. The handshake (TCP, TLS, HTTP upgrade) takes 30–80 ms on the LAN and a
            /// few hundred over a Tailscale relay; two seconds leaves room for that. Both keep
            /// quitting inside its 3 s grace: a stuck frame gives way in time for the held-key
            /// release and the video hang-up to go out. kvmd answers a ping at once; six seconds is
            /// three missed intervals, past a Wi-Fi hiccup or a retransmission, and a socket that
            /// silent is reconnected rather than left taking input it never delivers.
            static let standard = Timing(
                pingInterval: .seconds(2),
                sendTimeout: .seconds(1),
                openTimeout: .seconds(2),
                pongDeadline: .seconds(6)
            )
        }

        nonisolated let events: AsyncStream<GLKVMWebSocketEvent>
        private let continuation: AsyncStream<GLKVMWebSocketEvent>.Continuation

        /// Held so the session outlives the client that made this socket.
        private let session: GLKVMURLSession
        private let request: URLRequest
        private let timing: Timing
        private let log: SessionLog?
        /// Nil for a URLSession WebSocket task on `session`.
        private let makeSocket: (@Sendable (URLRequest) -> HIDSocket)?

        private var socket: HIDSocket?
        private var receiveTask: Task<Void, Never>?
        private var pingTask: Task<Void, Never>?
        /// When the last ping went out; cleared by the pong that answers it.
        private var pingSentAt: ContinuousClock.Instant?
        /// When the oldest ping still without a pong went out; nil while every ping is answered.
        private var unansweredPingSince: ContinuousClock.Instant?
        /// True once a frame has been sent successfully; cleared when the socket drops.
        private(set) var isConnected = false
        private(set) var isConnecting = false
        /// True once the device has sent a frame or the socket has taken one: the handshake is done.
        private var isOpen = false

        // Frames go out one at a time, in the order they were sent: see `transmit`.
        private var isSending = false
        /// Sends waiting for the one before them, resumed with false if the socket closes first.
        private var waitingToSend: [CheckedContinuation<Bool, Never>] = []
        private var sendInFlight: PendingSend?

        init(
            session: GLKVMURLSession,
            request: URLRequest,
            timing: Timing = .standard,
            log: SessionLog? = nil,
            makeSocket: (@Sendable (URLRequest) -> HIDSocket)? = nil
        ) {
            self.session = session
            self.request = request
            self.timing = timing
            self.log = log
            self.makeSocket = makeSocket

            var c: AsyncStream<GLKVMWebSocketEvent>.Continuation!
            self.events = AsyncStream { continuation in
                c = continuation
            }
            self.continuation = c
        }

        func connect() {
            guard socket == nil else { return }
            let ws: HIDSocket = makeSocket?(request) ?? URLSessionHIDSocket(session.session.webSocketTask(with: request))
            socket = ws
            isConnecting = true
            ws.resume()

            receiveTask = Task { [weak self] in
                guard let self else { return }
                await self.receiveLoop()
            }

            let interval = timing.pingInterval
            pingTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    if Task.isCancelled { break }
                    let check = await self.pingCheck()
                    if check == .notYetOpen {
                        // Nothing to ping yet; URLSession gives up on a handshake that never
                        // completes by itself.
                        continue
                    }
                    guard check == .due else { break }
                    do {
                        try await self.sendPing()
                    } catch {
                        // A failed ping is how a dropped socket is noticed.
                        await self.markDisconnected()
                        break
                    }
                }
            }
        }

        func disconnect() {
            close(abort: false)
        }

        /// Clears the keyboard report and releases every mouse button on the device, so a key or
        /// button that was down when the socket goes away does not stay down on the target.
        func releaseAllHIDInputs() async throws {
            try await sendBinary(Data([0x01, 0x00]))
            try await sendHidMouseButton(button: "left", state: false)
            try await sendHidMouseButton(button: "right", state: false)
            try await sendHidMouseButton(button: "middle", state: false)
        }

        /// A client is single-use: once its socket drops, the event stream ends so the owner
        /// notices (the ping loop is how a silently dead socket is caught), and the owner opens a
        /// fresh client rather than reconnecting this one.
        private func markDisconnected() {
            close(abort: true)
        }

        /// Returns without waiting for anything: a frame the socket is still holding, and every
        /// frame waiting behind it, fail at once instead of whenever (or if ever) it lets go.
        private func close(abort: Bool) {
            receiveTask?.cancel()
            receiveTask = nil
            pingTask?.cancel()
            pingTask = nil
            if abort {
                socket?.abort()
            } else {
                socket?.cancel(with: .goingAway, reason: nil)
            }
            socket = nil
            isConnected = false
            isConnecting = false
            sendInFlight?.end(.closed)
            sendInFlight = nil
            let waiting = waitingToSend
            waitingToSend.removeAll()
            waiting.forEach { $0.resume(returning: false) }
            continuation.finish()
        }

        private enum PingCheck {
            case due
            case notYetOpen
            /// No pong within the deadline; the socket has been closed.
            case silent
        }

        /// Whether to ping now. The deadline is checked once per ping interval, so a socket that
        /// stops answering is closed between `pongDeadline` and one interval after it.
        private func pingCheck() -> PingCheck {
            guard socket != nil else { return .silent }
            guard isOpen else { return .notYetOpen }
            if let since = unansweredPingSince {
                let silence = ContinuousClock.now - since
                if silence >= timing.pongDeadline {
                    log?.warning(.hid, "No pong from the device for \(Self.milliseconds(silence)) ms; closing the HID socket")
                    markDisconnected()
                    return .silent
                }
            }
            return .due
        }

        private func sendPing() async throws {
            let now = ContinuousClock.now
            pingSentAt = now
            if unansweredPingSince == nil {
                unansweredPingSince = now
            }
            try await send(eventType: "ping")
        }

        /// Attaches the measured round trip to a pong; other events pass through untouched.
        private func timed(_ event: GLKVMWebSocketEvent) -> GLKVMWebSocketEvent {
            guard event.eventType == "pong" else { return event }
            unansweredPingSince = nil
            guard let sentAt = pingSentAt else { return event }
            pingSentAt = nil
            var timedEvent = event
            timedEvent.roundTripMs = Self.milliseconds(ContinuousClock.now - sentAt)
            return timedEvent
        }

        private static func milliseconds(_ duration: Duration) -> Int {
            Int((duration / .milliseconds(1)).rounded())
        }

        func send(eventType: String, event: JSONValue = .object([:])) async throws {
            let payload = GLKVMWebSocketSend(eventType: eventType, event: event)
            let encoder = JSONEncoder()
            let data: Data
            do {
                data = try encoder.encode(payload)
            } catch {
                throw WebSocketError.encodingFailed
            }

            let text = String(decoding: data, as: UTF8.self)
            try await transmit(.string(text), describing: eventType)
        }

        private func sendBinary(_ data: Data) async throws {
            try await transmit(.data(data), describing: "HID report")
        }

        /// Puts one frame on the socket, after every frame sent before it. Every send goes through
        /// here, pings and input alike, so the socket is never asked to take two frames at once
        /// and they reach the device in the order they were sent. (The ping loop used to send on
        /// its own, overlapping whatever input was going out.)
        ///
        /// Each frame has a deadline. A socket that has not taken a frame by then has stopped
        /// draining: it is closed, the event stream ends so the owner reconnects, and the frames
        /// queued behind it fail at once instead of waiting on a socket that is gone.
        private func transmit(_ message: URLSessionWebSocketTask.Message, describing what: String) async throws {
            guard socket != nil else { throw WebSocketError.notConnected }
            if isSending {
                let isOurTurn = await withCheckedContinuation { waitingToSend.append($0) }
                guard isOurTurn else { throw WebSocketError.notConnected }
            } else {
                isSending = true
            }
            defer { passTheTurn() }

            guard let socket else { throw WebSocketError.notConnected }
            let deadline = isOpen ? timing.sendTimeout : timing.openTimeout
            let outcome: PendingSend.Outcome = await withCheckedContinuation { continuation in
                let pending = PendingSend(continuation)
                sendInFlight = pending
                socket.send(message) { error in
                    pending.end(error.map { PendingSend.Outcome.failed($0) } ?? .sent)
                }
                pending.startDeadline(deadline)
            }
            sendInFlight = nil

            switch outcome {
            case .sent:
                // The socket may have been dropped while the frame was in flight.
                guard self.socket === socket else { return }
                isOpen = true
                isConnecting = false
                isConnected = true
            case .failed(let error):
                throw error
            case .timedOut:
                if self.socket === socket {
                    log?.warning(
                        .hid,
                        "HID socket did not take a \(what) frame within \(Self.milliseconds(deadline)) ms; closing it"
                    )
                    markDisconnected()
                }
                throw WebSocketError.sendTimedOut
            case .closed:
                throw WebSocketError.notConnected
            }
        }

        private func passTheTurn() {
            if waitingToSend.isEmpty {
                isSending = false
            } else {
                waitingToSend.removeFirst().resume(returning: true)
            }
        }

        func sendHidKey(key: String, state: Bool, finish: Bool = false) async throws {
            var payload = Data()
            payload.reserveCapacity(2 + key.utf8.count)
            payload.append(0x01)
            payload.append(state ? 0x01 : 0x00)
            payload.append(contentsOf: key.utf8)
            try await sendBinary(payload)

            if finish {
                let finishPayload = Data([0x01, 0x00])
                try await sendBinary(finishPayload)
            }
        }

        func sendHidMouseButton(button: String, state: Bool) async throws {
            var payload = Data()
            payload.reserveCapacity(2 + button.utf8.count)
            payload.append(0x02)
            payload.append(state ? 0x01 : 0x00)
            payload.append(contentsOf: button.utf8)
            try await sendBinary(payload)
        }

        func sendHidMouseMove(toX: Int, toY: Int) async throws {
            let sx = Int16(clamping: toX)
            let sy = Int16(clamping: toY)
            let ux = UInt16(bitPattern: sx)
            let uy = UInt16(bitPattern: sy)
            let payload = Data([
                0x03,
                UInt8((ux >> 8) & 0xFF),
                UInt8(ux & 0xFF),
                UInt8((uy >> 8) & 0xFF),
                UInt8(uy & 0xFF),
            ])
            try await sendBinary(payload)
        }

        func sendHidMouseRelative(deltaX: Int, deltaY: Int, squash: Bool = false) async throws {
            let dx = UInt8(bitPattern: Int8(clamping: deltaX))
            let dy = UInt8(bitPattern: Int8(clamping: deltaY))
            let payload = Data([
                0x04,
                squash ? 0x01 : 0x00,
                dx,
                dy,
            ])
            try await sendBinary(payload)
        }

        func sendHidMouseWheel(deltaX: Int, deltaY: Int, squash: Bool = false) async throws {
            let dx = UInt8(bitPattern: Int8(clamping: deltaX))
            let dy = UInt8(bitPattern: Int8(clamping: deltaY))
            let payload = Data([
                0x05,
                squash ? 0x01 : 0x00,
                dx,
                dy,
            ])
            try await sendBinary(payload)
        }

        private func receiveLoop() async {
            let decoder = JSONDecoder()
            while !Task.isCancelled {
                guard let socket else { break }
                do {
                    let msg = try await socket.receive()
                    // kvmd sends its state as soon as the socket opens.
                    isOpen = true
                    switch msg {
                    case .string(let text):
                        guard let data = text.data(using: .utf8) else { continue }
                        if let event = try? decoder.decode(GLKVMWebSocketEvent.self, from: data) {
                            continuation.yield(timed(event))
                        }
                    case .data(let data):
                        if let event = try? decoder.decode(GLKVMWebSocketEvent.self, from: data) {
                            continuation.yield(timed(event))
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    markDisconnected()
                    break
                }
            }
        }

        /// One frame's wait for the socket, ended once by whichever comes first: the socket
        /// taking the frame (or failing it), the deadline, or the socket being closed. The
        /// socket's completion arrives on a URLSession queue, hence the lock.
        private final class PendingSend: @unchecked Sendable {
            enum Outcome: Sendable {
                case sent
                case failed(Error)
                case timedOut
                case closed
            }

            private let lock = NSLock()
            private var continuation: CheckedContinuation<Outcome, Never>?
            private var deadline: Task<Void, Never>?

            init(_ continuation: CheckedContinuation<Outcome, Never>) {
                self.continuation = continuation
            }

            func startDeadline(_ duration: Duration) {
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: duration)
                    guard !Task.isCancelled else { return }
                    self?.end(.timedOut)
                }
                let hasEnded = lock.withLock { () -> Bool in
                    guard continuation != nil else { return true }
                    deadline = timer
                    return false
                }
                if hasEnded {
                    timer.cancel()
                }
            }

            func end(_ outcome: Outcome) {
                let (continuation, deadline) = lock.withLock {
                    () -> (CheckedContinuation<Outcome, Never>?, Task<Void, Never>?) in
                    defer {
                        self.continuation = nil
                        self.deadline = nil
                    }
                    return (self.continuation, self.deadline)
                }
                deadline?.cancel()
                continuation?.resume(returning: outcome)
            }
        }
    }
}
