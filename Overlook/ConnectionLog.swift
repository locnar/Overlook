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

/// One line in the log: when, how bad, which layer, and what happened.
struct ConnectionLogEvent: Identifiable, Equatable, Sendable {
    let id: UInt64
    let date: Date
    let level: ConnectionLogLevel
    let category: ConnectionLogCategory
    let message: String
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
final class ConnectionLog: @unchecked Sendable {
    static let shared = ConnectionLog()

    /// Rotate past this size; three generations are kept.
    private static let maxFileBytes: UInt64 = 4 * 1024 * 1024
    private static let keptGenerations = 3
    /// Lines below this go to the ring (so the panel's "All" can show them) but not to the file
    /// or the unified log. Lowered to `.debug` by the `OverlookVerboseLogging` user default, for
    /// a session spent chasing something specific. Read once, so a change needs a relaunch.
    private let threshold: ConnectionLogLevel

    private let queue = DispatchQueue(label: "com.overlook.connection-log", qos: .utility)
    private let loggers: [ConnectionLogCategory: Logger]
    private let directoryURL: URL
    private let fileURL: URL
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

    private init() {
        var loggers: [ConnectionLogCategory: Logger] = [:]
        for category in ConnectionLogCategory.allCases {
            loggers[category] = Logger(subsystem: "com.rcawston.Overlook", category: category.rawValue)
        }
        self.loggers = loggers

        let base = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/Overlook", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Overlook", isDirectory: true)
        self.directoryURL = base
        self.fileURL = base.appendingPathComponent("connection.log", isDirectory: false)
        self.threshold = UserDefaults.standard.bool(forKey: "OverlookVerboseLogging") ? .debug : .info

        queue.async { [weak self] in
            self?.openFile()
            self?.writeSessionHeader()
        }
    }

    // MARK: - Recording

    func log(
        _ level: ConnectionLogLevel,
        _ category: ConnectionLogCategory,
        _ message: String
    ) {
        let date = Date()
        let id = counter.withLock { value -> UInt64 in
            value &+= 1
            return value
        }
        let event = ConnectionLogEvent(id: id, date: date, level: level, category: category, message: message)

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
        // cheap, and routing it through the file queue would reorder it against the file.
        loggers[category]?.log(level: level.osLogType, "\(message, privacy: .public)")

        queue.async { [weak self] in
            self?.appendToFile(event)
        }
    }

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
        let line = "\(Self.fileFormatter.string(from: event.date))  \(event.level.fileTag)  "
            + "[\(event.category.rawValue)] \(event.message)\n"
        writeRaw(line)
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

    var logDirectoryURL: URL { directoryURL }

    #if canImport(AppKit)
    /// Opens the log folder with `connection.log` selected.
    @MainActor
    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
    #endif
}

/// The bounded ring of recent events, for the Connections panel.
///
/// Capped because this is a debugging affordance, not an archive — the file is the archive.
/// A session that reconnects every few seconds for an hour must not grow the view's array
/// without bound.
@MainActor
final class ConnectionLogStore: ObservableObject {
    private static let capacity = 400

    @Published private(set) var events: [ConnectionLogEvent] = []

    /// Warnings and errors recorded since the operator last opened the log panel. Drives the dot
    /// on the toolbar button, so a problem is visible without opening anything.
    @Published private(set) var unseenProblemCount: Int = 0

    /// The most recent warning or error, for the two-line summary in the Connections panel.
    @Published private(set) var lastProblem: ConnectionLogEvent?

    /// `nonisolated` because the singleton that owns this store is built by `swift_once` on
    /// whichever thread logs first — routinely a URLSession delegate or one of libwebrtc's
    /// queues, not the main thread. Internal rather than fileprivate so tests can build a store
    /// of their own instead of sharing the app's.
    nonisolated init() {}

    /// True while the log panel is on screen. Problems arriving then are already being read, so
    /// they never raise the dot — which also keeps the panel from writing to a published property
    /// it is itself observing, mid-update.
    private var isPanelOpen = false

    /// Called when the log panel appears: the dot has done its job.
    func beginViewingProblems() {
        isPanelOpen = true
        guard unseenProblemCount != 0 else { return }
        unseenProblemCount = 0
    }

    func endViewingProblems() {
        isPanelOpen = false
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
        if isPanelOpen == false {
            unseenProblemCount += 1
        }
        // Ordered insert can place an older line ahead of one already recorded; the summary
        // should still name the newest problem, not whichever arrived last.
        if let current = lastProblem, current.id > event.id { return }
        lastProblem = event
    }

    func clear() {
        events.removeAll()
        unseenProblemCount = 0
        lastProblem = nil
    }
}

/// Shorthand so call sites read as one line. `clog.notice(.ice, "…")`.
let clog = ConnectionLog.shared
