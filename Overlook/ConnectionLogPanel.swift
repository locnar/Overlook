import SwiftUI
import AppKit

/// The connection log, as a right-edge panel with the same chrome as the settings panel.
///
/// A popover section could show a dozen lines; a reconnect round plus what led into it is about
/// thirty. That is the whole reason this is a panel — the operator opens it *after* something
/// went wrong and needs to scroll back through the minute before it, not watch it live.
///
/// Unlike Settings and OCR, this stays available while disconnected: a log is most wanted right
/// after a drop, which is exactly when there is no session.
struct ConnectionLogPanel: View {
    @EnvironmentObject private var logStore: ConnectionLogStore
    /// This window's session, whose lines "This window" shows.
    @Environment(\.connectionLogSessionID) private var sessionID

    @Binding var isPresented: Bool

    /// Persisted so the operator's chosen verbosity survives closing the panel.
    @AppStorage("OverlookLogPanelLevel") private var levelRaw: Int = ConnectionLogLevel.info.rawValue
    /// Per window, so one window showing every device leaves the others on their own.
    @SceneStorage("OverlookLogPanelShowsAllDevices") private var showsAllDevices = false
    @State private var category: ConnectionLogCategory?
    @State private var didCopy = false

    private static let panelBackground = Color(NSColor.windowBackgroundColor)

    private var level: ConnectionLogLevel {
        ConnectionLogLevel(rawValue: levelRaw) ?? .info
    }

    private var filter: ConnectionLogFilter {
        ConnectionLogFilter(
            scope: ConnectionLogFilter.scope(showsAllDevices: showsAllDevices, sessionID: sessionID),
            minimumLevel: level,
            category: category
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            filters
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()

            events

            Divider()

            footer
        }
        .background(Self.panelBackground)
        // The store stops counting problems while the panel is up — they are already on screen.
        // Doing it with a flag rather than clearing the count on each arrival keeps the panel
        // from writing to a published property it is itself observing, mid-update.
        .onAppear {
            if let sessionID { logStore.beginViewingProblems(for: sessionID) }
        }
        .onDisappear {
            if let sessionID { logStore.endViewingProblems(for: sessionID) }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)

            Text("Connection Log")
                .font(.headline)

            Spacer()

            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isPresented = false } }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding()
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $showsAllDevices) {
                Text("This window").tag(false)
                Text("All devices").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("This window's connection and the app's own events, or every window's")

            Picker("", selection: Binding(
                get: { level },
                set: { levelRaw = $0.rawValue }
            )) {
                Text("All").tag(ConnectionLogLevel.debug)
                Text("Info").tag(ConnectionLogLevel.info)
                Text("Problems").tag(ConnectionLogLevel.warning)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // A session produces far more `ice` and `stream` lines than anything else, so
            // narrowing to one layer is how this actually gets read. Nine chips do not fit one
            // row at the default width, and a horizontal scroller hid the last few off the
            // right edge — so they wrap, and collapse back toward one row as the panel widens.
            FlowLayout(spacing: 5, lineSpacing: 4) {
                CategoryChip(title: "all", isOn: category == nil) { category = nil }
                ForEach(ConnectionLogCategory.allCases, id: \.self) { candidate in
                    CategoryChip(
                        title: candidate.rawValue,
                        isOn: category == candidate
                    ) {
                        category = (category == candidate) ? nil : candidate
                    }
                }
            }
        }
    }

    private var events: some View {
        Group {
            if visibleEvents.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "text.append")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(visibleEvents) { event in
                            ConnectionLogRow(event: event, showsDevice: filter.showsDeviceTags)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Reveal Log in Finder") {
                ConnectionLog.shared.revealInFinder()
            }
            .buttonStyle(.link)

            Spacer()

            Button(didCopy ? "Copied" : "Copy") {
                let text = visibleEvents
                    .reversed()
                    .map { ConnectionLogRow.plainText($0) }
                    .joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                didCopy = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    didCopy = false
                }
            }
            .buttonStyle(.link)
            .disabled(visibleEvents.isEmpty)
            .help("Copy the visible lines, oldest first")

            Button("Clear") {
                logStore.clear(filter.scope)
            }
            .buttonStyle(.link)
            .foregroundColor(.secondary)
            .disabled(logStore.events(in: filter.scope).isEmpty)
            .help("Clears this list only; the file on disk is untouched")
        }
        .font(.caption)
        .padding()
    }

    // MARK: - Filtering

    private var visibleEvents: [ConnectionLogEvent] {
        filter.apply(to: logStore.events)
    }

    private var emptyMessage: String {
        filter.emptyMessage(hasEventsInScope: !logStore.events(in: filter.scope).isEmpty)
    }
}

/// What the log panel shows: whose lines ("This window" or "All devices"), from which level up,
/// and of which category. No SwiftUI state here, so the choice of lines can be tested.
struct ConnectionLogFilter: Equatable {
    var scope: ConnectionLogScope
    var minimumLevel: ConnectionLogLevel
    var category: ConnectionLogCategory?

    /// "All devices" when asked for, or when the view has no session to narrow to.
    static func scope(showsAllDevices: Bool, sessionID: UUID?) -> ConnectionLogScope {
        guard !showsAllDevices, let sessionID else { return .allDevices }
        return .session(sessionID)
    }

    /// With every device's lines in one list, each line names its device.
    var showsDeviceTags: Bool { scope == .allDevices }

    func apply(to events: [ConnectionLogEvent]) -> [ConnectionLogEvent] {
        events.filter { event in
            scope.includes(event)
                && event.level >= minimumLevel
                && (category == nil || event.category == category)
        }
    }

    /// What an empty list says, for either scope: nothing recorded at all, or nothing at this
    /// level or in this category.
    func emptyMessage(hasEventsInScope: Bool) -> String {
        if !hasEventsInScope {
            switch scope {
            case .session:
                return "Nothing recorded for this window yet.\nEvents appear here as its connection does things."
            case .allDevices:
                return "Nothing recorded yet.\nEvents appear here as connections do things."
            }
        }
        if let category {
            return "No \(category.rawValue) events at this level."
        }
        return "No events at this level."
    }
}

/// One category filter. A plain capsule rather than a `Picker`, because the set is wider than a
/// segmented control fits and any one of them can be switched off again.
private struct CategoryChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(isOn ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07))
                )
                .overlay(
                    Capsule().strokeBorder(isOn ? Color.accentColor : .clear, lineWidth: 1)
                )
                .foregroundColor(isOn ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }
}

/// One event: time, category, message, and with "All devices" the device it came from. Severity
/// is colour rather than a word, so the message keeps the width.
struct ConnectionLogRow: View {
    let event: ConnectionLogEvent
    var showsDevice = false

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// As the file has it, device tag included: `21:14:05  NOTE  [ice] [192.168.0.131] message`.
    static func plainText(_ event: ConnectionLogEvent) -> String {
        "\(formatter.string(from: event.date))  \(event.level.fileTag)  [\(event.category.rawValue)] \(event.taggedMessage)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text(Self.formatter.string(from: event.date))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)

            Text(event.category.rawValue)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 58, alignment: .leading)

            if showsDevice, let device = event.source?.device {
                Text(device)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    // Wide enough for an address and port; a long host name is shortened in the
                    // middle rather than squeezing the message.
                    .frame(maxWidth: 120, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(device)
            }

            Text(event.message)
                .font(.caption2)
                .foregroundColor(Self.color(for: event.level))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }

    static func color(for level: ConnectionLogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info, .notice: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }
}


/// Lays subviews out left to right, wrapping to a new line when the next one would not fit.
///
/// `HStack` cannot wrap and a `LazyVGrid` would force every chip into a column of the same
/// width, which looks wrong when the labels run from "ice" to "signaling". Each subview keeps
/// its natural size here, and the number of rows falls out of however wide the panel is.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height }
            + lineSpacing * CGFloat(max(0, rows.count - 1))
        // Take the full proposed width when there is one, so the container doesn't shrink-wrap
        // to the longest row and leave the rows looking ragged against the panel edge.
        return CGSize(width: proposal.width ?? (rows.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let widthWithThis = current.indices.isEmpty
                ? size.width
                : current.width + spacing + size.width

            // A subview wider than the whole row still goes on a row of its own rather than
            // being dropped.
            if widthWithThis > maxWidth, current.indices.isEmpty == false {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = widthWithThis
                current.height = max(current.height, size.height)
            }
        }

        if current.indices.isEmpty == false { rows.append(current) }
        return rows
    }
}
