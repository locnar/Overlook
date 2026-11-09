import Foundation
import Testing
@testable import Overlook

/// Requests answered by transaction (`create`, `attach`) and the answers the signaling listener
/// hands back. No socket is involved: each test's `send` stands in for one, and delivers the
/// answer itself where the device would.
@MainActor
@Suite("Janus transactions")
struct JanusTransactionTests {
    struct TimedOut: Error {}

    @MainActor
    final class Flag {
        var isSet = false
    }

    private func transactions(timeoutMs: UInt64 = 5_000) -> JanusTransactions {
        JanusTransactions(timeoutNanoseconds: timeoutMs * 1_000_000, timeoutError: TimedOut())
    }

    private func answer(_ transaction: String, id: Int) -> [String: Any] {
        ["janus": "success", "transaction": transaction, "data": ["id": id]]
    }

    private func id(in reply: [String: Any]) -> Int? {
        (reply["data"] as? [String: Any])?["id"] as? Int
    }

    @Test func anAnswerHandledBeforeTheSendFinishesIsReceived() async throws {
        // The bug this guards: the listener read a fast answer while the send was still
        // suspended, found no waiter, and the connect timed out eight seconds later.
        let table = transactions()
        let delivered = Flag()
        let start = ContinuousClock.now

        let reply = try await table.request("create-1") {
            delivered.isSet = table.deliver(self.answer("create-1", id: 42))
        }

        #expect(delivered.isSet)
        #expect(id(in: reply) == 42)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(table.count == 0)
    }

    @Test func anAnswerAfterTheSendIsReceived() async throws {
        let table = transactions()
        let waiting = Task { self.id(in: try await table.request("attach-1") {}) }
        #expect(await waitUntil { table.count == 1 })

        #expect(table.deliver(answer("attach-1", id: 7)))

        #expect(try await waiting.value == 7)
        #expect(table.count == 0)
    }

    @Test func aRequestNobodyAnswersTimesOut() async throws {
        let table = transactions(timeoutMs: 100)

        await #expect(throws: TimedOut.self) {
            _ = try await table.request("create-2") {}
        }
        #expect(table.count == 0)
        // An answer that turns up after the timeout is nobody's; the listener handles it as a
        // notification.
        #expect(table.deliver(answer("create-2", id: 1)) == false)
    }

    @Test func aSendThatNeverFinishesTimesOut() async throws {
        let table = transactions(timeoutMs: 100)
        let latch = Latch()

        await #expect(throws: TimedOut.self) {
            _ = try await table.request("create-3") { await latch.wait() }
        }
        #expect(table.count == 0)
        await latch.open()
    }

    @Test func aFailedSendFailsTheRequestAtOnce() async throws {
        let table = transactions(timeoutMs: 30_000)
        let start = ContinuousClock.now

        await #expect(throws: TestError(name: "socket closed")) {
            _ = try await table.request("attach-2") { throw TestError(name: "socket closed") }
        }
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(table.count == 0)
    }

    @Test func aTeardownEndsEveryWaitingRequest() async throws {
        let table = transactions(timeoutMs: 30_000)
        let first = Task { _ = try await table.request("a") {} }
        let second = Task { _ = try await table.request("b") {} }
        #expect(await waitUntil { table.count == 2 })

        table.failAll(TestError(name: "torn down"))

        await #expect(throws: TestError(name: "torn down")) { try await first.value }
        await #expect(throws: TestError(name: "torn down")) { try await second.value }
        #expect(table.count == 0)
    }

    @Test func onlyTheWaitedOnTransactionIsTaken() async throws {
        let table = transactions()
        let waiting = Task { self.id(in: try await table.request("mine") {}) }
        #expect(await waitUntil { table.count == 1 })

        // A keepalive's ack, an event and an answer to another transaction are not this
        // request's, and must reach the notification handling untouched.
        #expect(table.deliver(["janus": "ack", "transaction": "keepalive-1"]) == false)
        #expect(table.deliver(["janus": "event", "sender": 1]) == false)
        #expect(table.deliver(answer("someone-else", id: 3)) == false)
        #expect(table.count == 1)

        #expect(table.deliver(answer("mine", id: 9)))
        #expect(try await waiting.value == 9)
    }
}
