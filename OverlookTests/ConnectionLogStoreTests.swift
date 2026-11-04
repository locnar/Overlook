import Foundation
import Testing
@testable import Overlook

/// The in-memory ring behind the log panel. Each test builds its own store; the app's
/// `ConnectionLog.shared.store` is left alone.
@MainActor
@Suite("Connection log store")
struct ConnectionLogStoreTests {
    private func event(
        _ id: UInt64,
        _ level: ConnectionLogLevel = .info,
        _ message: String = ""
    ) -> ConnectionLogEvent {
        ConnectionLogEvent(
            id: id,
            date: Date(timeIntervalSince1970: TimeInterval(id)),
            level: level,
            category: .lifecycle,
            message: message.isEmpty ? "event \(id)" : message
        )
    }

    @Test func keepsTheNewestFirst() {
        let store = ConnectionLogStore()
        store.append(event(1))
        store.append(event(2))
        store.append(event(3))
        #expect(store.events.map(\.id) == [3, 2, 1])
    }

    @Test func placesALateArrivalByIDRatherThanArrival() {
        let store = ConnectionLogStore()
        store.append(event(1))
        store.append(event(4))
        store.append(event(2))
        store.append(event(3))
        #expect(store.events.map(\.id) == [4, 3, 2, 1])
    }

    @Test func dropsTheOldestPastCapacity() {
        let store = ConnectionLogStore()
        for id in 1...405 {
            store.append(event(UInt64(id)))
        }
        #expect(store.events.count == 400)
        #expect(store.events.first?.id == 405)
        #expect(store.events.last?.id == 6)
    }

    @Test func countsWarningsAndErrorsButNothingQuieter() {
        let store = ConnectionLogStore()
        store.append(event(1, .debug))
        store.append(event(2, .info))
        store.append(event(3, .notice))
        #expect(store.unseenProblemCount == 0)
        #expect(store.lastProblem == nil)

        store.append(event(4, .warning))
        store.append(event(5, .error))
        #expect(store.unseenProblemCount == 2)
        #expect(store.lastProblem?.id == 5)
    }

    @Test func viewingTheLogClearsAndSuppressesTheCount() {
        let store = ConnectionLogStore()
        store.append(event(1, .warning))
        store.beginViewingProblems()
        #expect(store.unseenProblemCount == 0)

        store.append(event(2, .error))
        #expect(store.unseenProblemCount == 0)
        // Still the summary's problem, even though it was seen as it arrived.
        #expect(store.lastProblem?.id == 2)

        store.endViewingProblems()
        store.append(event(3, .warning))
        #expect(store.unseenProblemCount == 1)
    }

    @Test func lastProblemIsTheNewestEvenWhenAnOlderOneArrivesLate() {
        let store = ConnectionLogStore()
        store.append(event(10, .error, "newer"))
        store.append(event(7, .warning, "older"))
        #expect(store.lastProblem?.message == "newer")
        #expect(store.unseenProblemCount == 2)
    }

    @Test func clearEmptiesEverything() {
        let store = ConnectionLogStore()
        store.append(event(1, .error))
        store.clear()
        #expect(store.events.isEmpty)
        #expect(store.unseenProblemCount == 0)
        #expect(store.lastProblem == nil)
    }

    @Test func levelsOrderAndTagAsTheFileExpects() {
        #expect(ConnectionLogLevel.debug < .info)
        #expect(ConnectionLogLevel.warning < .error)
        #expect([ConnectionLogLevel.debug, .info, .notice, .warning, .error].map(\.fileTag)
            == ["DBUG", "INFO", "NOTE", "WARN", "FAIL"])
    }

    @Test func categoriesAreTheUnifiedLogCategories() {
        // These are `log stream` predicates people have written down; renaming one breaks them.
        #expect(ConnectionLogCategory.allCases.map(\.rawValue) == [
            "lifecycle", "signaling", "ice", "stream", "hid", "device", "power", "network",
        ])
    }
}
