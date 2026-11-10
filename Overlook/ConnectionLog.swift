import Foundation
import os

#if canImport(AppKit)
import AppKit
#endif

/// Why a connection event was recorded. Categories are the unified-log subsystem's categories
/// too, so `log stream --predicate 'subsystem == "com.rcawston.Overlook" && category == "ice"'`
/// narrows to one layer without touching the file.
enum ConnectionLogCategory: String, CaseIterable, Sendable {
    /// Operator-driven connects, disconnects, and reconnect loops.
    case lifecycle
    /// The Janus WebSocket: session create/attach, keepalives, and everything the server pushes.
    case signaling
    /// ICE gathering, candidate pairs, and connection-state transitions.
    case ice
    /// Video and audio flow: stalls, freezes, first frame, slow links.
    case stream
    /// The HID WebSocket that carries keyboard and mouse.
    case hid
    /// The GLKVM HTTP API and what the device reports about itself.
    case device
    /// Sleep, wake, App Nap, and the activity assertion.
    case power
    /// Interface changes as `NWPathMonitor` sees them.
    case network
}

enum ConnectionLogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case notice = 2
    case warning = 3
    case error = 4

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Four characters wide so the file's columns line up when scanned by eye.
    var fileTag: String {
        switch self {
        case .debug: return "DBUG"
        case .info: return "INFO"
        case .notice: return "NOTE"
        case .warning: return "WARN"
        case .error: return "FAIL"
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning: return .default
        case .error: return .error
        }
    }
}

/// Which console session a line came from, and the device it was talking to, so lines from two
/// windows can be told apart. App-level lines (scanning, launch) have none.
struct ConnectionLogSource: Equatable, Sendable {
    /// The session's `SessionLog.sessionID`: what the log panel's "This window" matches on.
    let sessionID: UUID
    /// The device as the file and the panel show it (`SessionLog.label(host:port:)`), or nil
    /// for a line logged before the session first connected.
    let device: String?
}

/// One line in the log: when, how bad, which layer, which session and device, and what happened.
struct ConnectionLogEvent: Identifiable, Equatable, Sendable {
    let id: UInt64
    let date: Date
    let level: ConnectionLogLevel
    let category: ConnectionLogCategory
    let message: String
    let source: ConnectionLogSource?

    init(
        id: UInt64,
        date: Date,
        level: ConnectionLogLevel,
        category: ConnectionLogCategory,
        message: String,
        source: ConnectionLogSource? = nil
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
        self.source = source
    }

    /// The device tag, as it appears after the category in the file and in copied text.
    var deviceTag: String? {
        source?.device.map { "[\($0)]" }
    }

    /// The message with the device tag in front when there is one: `[192.168.0.131] Connected`.
    var taggedMessage: String {
        deviceTag.map { "\($0) \(message)" } ?? message
    }
}

/// Anything lines can be logged to: the app's own log, which leaves them untagged, or one
/// session's handle on it (`SessionLog`), which tags them with that session and its device.
protocol ConnectionLogging: Sendable {
    func log(_ level: ConnectionLogLevel, _ category: ConnectionLogCategory, _ message: String)
}

extension ConnectionLogging {
    func debug(_ category: ConnectionLogCategory, _ message: String) {
        log(.debug, category, message)
    }

    func info(_ category: ConnectionLogCategory, _ message: String) {
        log(.info, category, message)
    }

    func notice(_ category: ConnectionLogCategory, _ message: String) {
        log(.notice, category, message)
    }

    func warning(_ category: ConnectionLogCategory, _ message: String) {
        log(.warning, category, message)
    }

    func error(_ category: ConnectionLogCategory, _ message: String) {
        log(.error, category, message)
    }
}

/// The connection log: a rotating file under `~/Library/Logs/Overlook/`, a mirror into the
/// unified log, and a bounded in-memory ring the Connections panel renders.
///
/// Callable from any thread — WebRTC delegate callbacks arrive on libwebrtc's own queues and
/// must not be made to hop just to record a line. File writes are serialized onto a private
/// queue; only the ring's publish hops to the main actor.
///
/// Why a file at all, when the unified log exists: `log show` keeps entries for a bounded
/// window and drops `.debug`/`.info` unless the process is being streamed live. A disconnect
/// noticed twenty minutes later needs a record that was already on disk when it happened.
final class ConnectionLog: ConnectionLogging, @unchecked Sendable {
    /// The app's log. Under the test host it is kept in memory, like `inMemory()`, so a test run
    /// never writes to the operator's file.
    static let shared: ConnectionLog = AppEnvironment.isHostingTests ? .inMemory() : ConnectionLog(
        directory: FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/Overlook", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Overlook", isDirectory: true),
        mirrorsToUnifiedLog: true,
        threshold: UserDefaults.standard.bool(forKey: "OverlookVerboseLogging") ? .debug : .info
    )

    /// A log with only the in-memory ring: no file, nothing in the unified log. For tests, which
    /// must not write to the operator's log.
    static func inMemory() -> ConnectionLog {
        ConnectionLog(directory: nil, mirrorsToUnifiedLog: false, threshold: .info)
    }

    /// Whether lines go to `connection.log`. False for a log kept in memory.
    var writesFile: Bool { fileURL != nil }

    /// Rotate past this size; three generations are kept.
    private static let maxFileBytes: UInt64 = 4 * 1024 * 1024
    private static let keptGenerations = 3
    /// Lines below this go to the ring (so the panel's "All" can show them) but not to the file
    /// or the unified log. Lowered to `.debug` by the `OverlookVerboseLogging` user default, for
    /// a session spent chasing something specific. Read once, so a change needs a relaunch.
    private let threshold: ConnectionLogLevel

    private let queue = DispatchQueue(label: "com.overlook.connection-log", qos: .utility)
    private let loggers: [ConnectionLogCategory: Logger]
    /// Nil for a log kept in memory only.
    private let directoryURL: URL?
    private let fileURL: URL?
    private var handle: FileHandle?
    private var bytesWritten: UInt64 = 0
    private let counter = OSAllocatedUnfairLock(initialState: UInt64(0))

    /// The ring the UI observes. Separate object so a log line invalidates only the timeline.
    let store = ConnectionLogStore()

    private static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = .current
        return formatter
    }()

    private init(directory: URL?, mirrorsToUnifiedLog: Bool, threshold: ConnectionLogLevel) {
        var loggers: [ConnectionLogCategory: Logger] = [:]
        if mirrorsToUnifiedLog {
            for category in ConnectionLogCategory.allCases {
                loggers[category] = Logger(subsystem: "com.rcawston.Overlook", category: category.rawValue)
            }
        }
        self.loggers = loggers

        self.directoryURL = directory
        self.fileURL = directory?.appendingPathComponent("connection.log", isDirectory: false)
        self.threshold = threshold

        guard directory != nil else { return }
        queue.async { [weak self] in
            self?.openFile()
            self?.writeSessionHeader()
        }
    }

    // MARK: - Recording

    /// An app-level line, belonging to no session.
    func log(
        _ level: ConnectionLogLevel,
        _ category: ConnectionLogCategory,
        _ message: String
    ) {
        record(level, category, message, source: nil)
    }

    /// A line from `source`'s session, or an app-level one when it is nil. `SessionLog` comes here.
    func record(
        _ level: ConnectionLogLevel,
        _ category: ConnectionLogCategory,
        _ message: String,
        source: ConnectionLogSource?
    ) {
        let date = Date()
        let id = counter.withLock { value -> UInt64 in
            value &+= 1
            return value
        }
        let event = ConnectionLogEvent(id: id, date: date, level: level, category: category, message: message, source: source)

        // The ring takes every line regardless of threshold, so the panel's "All" filter has
        // something the "Info" filter doesn't. It is capped, and this is the copy an operator
        // reads seconds after a drop.
        //
        // Capture the store directly rather than going back through `shared`: a line logged
        // while the singleton is still initializing would otherwise re-enter it.
        let store = self.store
        Task { @MainActor in
            store.append(event)
        }

        guard level >= threshold else { return }

        // The unified log takes the line on the calling thread: os_log is already lock-free and
        // cheap, and routing it through the file queue would reorder it against the file. It gets
        // the device tag too, so `log stream` can tell two windows' lines apart as the file can.
        let taggedMessage = event.taggedMessage
        loggers[category]?.log(level: level.osLogType, "\(taggedMessage, privacy: .public)")

        guard fileURL != nil else { return }
        queue.async { [weak self] in
            self?.appendToFile(event)
        }
    }

    // MARK: - File

    /// Everything needed to read a log someone mailed you a week later without asking follow-up
    /// questions: which build, which OS, which machine.
    private func writeSessionHeader() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var model = "unknown"
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0,
               let name = String(validatingCString: buffer), !name.isEmpty {
                model = name
            }
        }

        let separator = String(repeating: "=", count: 72)
        writeRaw("\n\(separator)\n")
        writeRaw("Overlook \(version) (\(build)) · \(os) · \(model)\n")
        writeRaw("Session started \(Self.fileFormatter.string(from: Date()))\n")
        writeRaw("\(separator)\n")
    }

    private func openFile() {
        guard let directoryURL, let fileURL else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        if let handle {
            bytesWritten = (try? handle.seekToEnd()) ?? 0
        }
    }

    private func appendToFile(_ event: ConnectionLogEvent) {
        writeRaw(Self.fileLine(for: event) + "\n")
    }

    /// One line of the file: time, level, category, the device for a session's line, message.
    /// `2026-11-03 21:14:05.120  NOTE  [ice] [192.168.0.131] Video ICE state: connected`. A line
    /// from no session reads as it always has.
    static func fileLine(for event: ConnectionLogEvent) -> String {
        "\(fileFormatter.string(from: event.date))  \(event.level.fileTag)  "
            + "[\(event.category.rawValue)] \(event.taggedMessage)"
    }

    private func writeRaw(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if handle == nil { openFile() }
        guard let handle else { return }
        try? handle.write(contentsOf: data)
        bytesWritten += UInt64(data.count)
        if bytesWritten > Self.maxFileBytes {
            rotate()
        }
    }

    /// `connection.log` → `connection.1.log` → … → dropped. Called on the log queue only.
    private func rotate() {
        guard let directoryURL, let fileURL else { return }
        let manager = FileManager.default
        try? handle?.close()
        handle = nil

        let oldest = directoryURL.appendingPathComponent("connection.\(Self.keptGenerations).log")
        try? manager.removeItem(at: oldest)
        for generation in stride(from: Self.keptGenerations - 1, through: 1, by: -1) {
            let from = directoryURL.appendingPathComponent("connection.\(generation).log")
            let to = directoryURL.appendingPathComponent("connection.\(generation + 1).log")
            guard manager.fileExists(atPath: from.path) else { continue }
            try? manager.removeItem(at: to)
            try? manager.moveItem(at: from, to: to)
        }
        let first = directoryURL.appendingPathComponent("connection.1.log")
        try? manager.removeItem(at: first)
        try? manager.moveItem(at: fileURL, to: first)

        bytesWritten = 0
        openFile()
    }

    // MARK: - Operator affordances

    var logDirectoryURL: URL? { directoryURL }

    #if canImport(AppKit)
    /// Opens the log folder with `connection.log` selected.
    @MainActor
    func revealInFinder() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
    #endif
}

/// One console session's handle on the connection log: the same calls as `clog`, with each line
/// tagged with the session and the device it is talking to.
///
/// The session hands it to each of its objects explicitly (stream, keyboard and mouse, sign-in,
/// certificate pinning) rather than putting it in a task-local, because most of their lines are
/// logged from delegate callbacks, timers and URLSession queues that no task-local reaches.
final class SessionLog: ConnectionLogging, @unchecked Sendable {
    /// Matches this session's lines in the panel's "This window".
    let sessionID = UUID()
    /// Where the lines go: `ConnectionLog.shared` in the app, a log in memory in tests.
    let destination: ConnectionLog
    private let device = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(destination: ConnectionLog) {
        self.destination = destination
    }

    /// The device this session's lines are tagged with. Set when a connect starts and kept after
    /// a disconnect, so the hang-up and anything still arriving from the old connection are
    /// tagged with the device they belong to. Lines can come from any thread, hence the lock.
    var deviceLabel: String? {
        get { device.withLock { $0 } }
        set { device.withLock { $0 = newValue } }
    }

    func log(_ level: ConnectionLogLevel, _ category: ConnectionLogCategory, _ message: String) {
        destination.record(level, category, message, source: ConnectionLogSource(sessionID: sessionID, device: deviceLabel))
    }

    /// The ring this session's window shows.
    var store: ConnectionLogStore { destination.store }

    /// A short name for a device: its host as it was entered, with the port only when it is not
    /// the scheme's own (443 for HTTPS, 80 for HTTP). `192.168.0.131`, `mdesktopkvm`,
    /// `mdesktopkvm.tail1234.ts.net`, `kvm.local:8443`.
    ///
    /// A Tailscale name keeps its tailnet suffix: a bare MagicDNS name and the full `.ts.net` one
    /// are different addresses (they can be saved as different devices), and a menu that showed
    /// both as `mdesktopkvm` could not tell them apart.
    static func label(host: String, port: Int) -> String {
        var shownHost = host
        if port == 443 || port == 80 {
            return shownHost
        }
        // An IPv6 literal needs brackets before a port can follow it.
        if shownHost.contains(":") {
            shownHost = "[\(shownHost)]"
        }
        return "\(shownHost):\(port)"
    }
}

/// Which of the log's lines a view shows.
enum ConnectionLogScope: Hashable {
    /// One window's: its session's lines, and the app's own, which belong to no window.
    case session(UUID)
    /// Every session's, and the app's.
    case allDevices

    func includes(_ event: ConnectionLogEvent) -> Bool {
        switch self {
        case .allDevices:
            return true
        case .session(let id):
            guard let source = event.source else { return true }
            return source.sessionID == id
        }
    }
}

/// The bounded ring of recent events, for the log panel and the Connections panel, shared by
/// every window. Each window shows its own session's lines from it, or every device's.
///
/// Capped because this is a debugging affordance, not an archive — the file is the archive.
/// A session that reconnects every few seconds for an hour must not grow the view's array
/// without bound.
@MainActor
final class ConnectionLogStore: ObservableObject {
    private static let capacity = 400

    @Published private(set) var events: [ConnectionLogEvent] = []

    /// The most recent warning or error from each session, and from the app (the nil key), for
    /// the two-line summary in the Connections panel. Kept apart from the ring so a problem is
    /// still summarized after newer lines have pushed it out. Changes only with `events`, which is
    /// what views observe.
    private var lastProblems: [UUID?: ConnectionLogEvent] = [:]

    /// The windows whose log panel is on screen, by session. Problems arriving there are already
    /// being read, so they never raise that window's dot.
    private var viewing: Set<UUID> = []
    /// For each window, the newest line there was when its log panel last closed: problems after
    /// it are the ones its dot counts.
    private var seenThrough: [UUID: UInt64] = [:]

    /// `nonisolated` because the singleton that owns this store is built by `swift_once` on
    /// whichever thread logs first — routinely a URLSession delegate or one of libwebrtc's
    /// queues, not the main thread. Internal rather than fileprivate so tests can build a store
    /// of their own instead of sharing the app's.
    nonisolated init() {}

    /// The lines `scope` shows, newest first.
    func events(in scope: ConnectionLogScope) -> [ConnectionLogEvent] {
        scope == .allDevices ? events : events.filter(scope.includes)
    }

    /// The most recent warning or error `scope` covers.
    func lastProblem(in scope: ConnectionLogScope) -> ConnectionLogEvent? {
        let candidates: [ConnectionLogEvent]
        switch scope {
        case .allDevices:
            candidates = Array(lastProblems.values)
        case .session(let id):
            candidates = [lastProblems[id], lastProblems[nil]].compactMap { $0 }
        }
        return candidates.max { $0.id < $1.id }
    }

    /// Warnings and errors in the window of `sessionID` (its session's and the app's) since that
    /// window's log panel was last open. Drives the dot on its toolbar button, so a problem is
    /// visible without opening anything.
    func unseenProblemCount(for sessionID: UUID) -> Int {
        guard !viewing.contains(sessionID) else { return 0 }
        let scope = ConnectionLogScope.session(sessionID)
        let seen = seenThrough[sessionID] ?? 0
        return events.reduce(0) { count, event in
            event.level >= .warning && event.id > seen && scope.includes(event) ? count + 1 : count
        }
    }

    /// Called when a window's log panel appears: that window's dot has done its job. Problems
    /// arriving while it is open are not counted, which also keeps the panel from writing to a
    /// published property it is itself observing, mid-update.
    func beginViewingProblems(for sessionID: UUID) {
        if unseenProblemCount(for: sessionID) > 0 {
            objectWillChange.send()
        }
        viewing.insert(sessionID)
    }

    func endViewingProblems(for sessionID: UUID) {
        viewing.remove(sessionID)
        // Nothing on screen changes: the count was zero while the panel was open, and every line
        // up to now has been seen.
        seenThrough[sessionID] = events.first?.id ?? seenThrough[sessionID]
    }

    /// Newest first, ordered by the log's monotonic id rather than arrival.
    ///
    /// Each line hops to the main actor in its own task, and tasks enqueued from different
    /// threads have no ordering guarantee between them — inserting blindly at index 0 lets a
    /// line from a WebRTC delegate queue jump ahead of one logged a moment later. The common
    /// case is still a single comparison: the newest id almost always belongs at the front.
    func append(_ event: ConnectionLogEvent) {
        if let newest = events.first, newest.id > event.id {
            let index = events.firstIndex { $0.id < event.id } ?? events.endIndex
            events.insert(event, at: index)
        } else {
            events.insert(event, at: 0)
        }
        if events.count > Self.capacity {
            events.removeLast(events.count - Self.capacity)
        }

        guard event.level >= .warning else { return }
        // Ordered insert can place an older line ahead of one already recorded; the summary
        // should still name the newest problem, not whichever arrived last.
        let key = event.source?.sessionID
        if let current = lastProblems[key], current.id > event.id { return }
        lastProblems[key] = event
    }

    /// Clears the lines `scope` shows, and the problems summarized from them. "This window"
    /// leaves other windows' lines alone. The file is untouched either way.
    func clear(_ scope: ConnectionLogScope) {
        switch scope {
        case .allDevices:
            events.removeAll()
            lastProblems.removeAll()
        case .session(let id):
            events.removeAll { scope.includes($0) }
            lastProblems[id] = nil
            lastProblems[nil] = nil
        }
    }
}

/// Shorthand so call sites read as one line. `clog.notice(.ice, "…")`.
let clog = ConnectionLog.shared
