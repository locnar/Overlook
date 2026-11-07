import Foundation
import Testing
@testable import Overlook

@Suite("Paste parts")
struct PastePartsTests {
    @Test func asciiIsSplitAtTheLimitAndJoinsBackUnchanged() {
        let text = String(repeating: "abcdefghij", count: 110)  // 1,100 characters
        let parts = RemotePasteQueue.parts(of: text, maxScalars: 512)

        #expect(parts.map(\.count) == [512, 512, 76])
        #expect(parts.joined() == text)
    }

    @Test func shortTextIsOnePart() {
        #expect(RemotePasteQueue.parts(of: "ls -la", maxScalars: 512) == ["ls -la"])
        #expect(RemotePasteQueue.parts(of: "", maxScalars: 512).isEmpty)
    }

    @Test func emojiAndCombiningMarksAreNeverSplit() {
        let family = "👨‍👩‍👧"  // five code points, one character
        let flag = "🇩🇪"  // two code points
        let accented = "e\u{0301}"  // e + combining acute
        let text = "ab" + family + flag + accented + "z"
        let parts = RemotePasteQueue.parts(of: text, maxScalars: 4)

        #expect(parts.joined() == text)
        #expect(parts.contains(family))
        for part in parts {
            // Within the limit, unless it is one character longer than the limit on its own.
            #expect(part.unicodeScalars.count <= 4 || part.count == 1)
        }
        #expect(parts == ["ab", family, flag + accented, "z"])
    }

    @Test func aCRLFIsNeverSplit() {
        let text = "a\r\nb\r\nc"
        let parts = RemotePasteQueue.parts(of: text, maxScalars: 2)

        #expect(parts == ["a", "\r\n", "b", "\r\n", "c"])
        #expect(!parts.contains { $0.hasSuffix("\r") || $0.hasPrefix("\n") })
    }

    @Test func partsCountCodePointsTheWayTheDeviceDoes() {
        // 300 two-code-point characters are 600 code points: two parts at 512.
        let text = String(repeating: "🇩🇪", count: 300)
        let parts = RemotePasteQueue.parts(of: text, maxScalars: 512)

        #expect(parts.map { $0.unicodeScalars.count } == [512, 88])
        #expect(parts.joined() == text)
    }
}

/// Pastes through an input manager connected to a stubbed device.
@MainActor
@Suite("Remote paste")
struct RemotePasteTests {
    let scratch = ScratchDefaults()
    let device = StubDevice()
    let input: InputManager

    init() throws {
        input = InputManager(defaults: scratch.defaults, log: SessionLog(destination: .inMemory()))
        // No HID socket: these tests are about the HTTP print path only.
        input.transportMode = .webRTC
        input.setGLKVMClient(try device.makeClient())
    }

    private var prints: [StubDevice.Request] {
        device.requests(to: "/api/hid/print")
    }

    @Test func printSendsLimitZeroSoTheDeviceDoesNotTruncate() async throws {
        let client = try device.makeClient()
        try await client.hidPrint(text: "hello", keymap: "en-us")

        let request = try #require(device.requests(to: "/api/hid/print").first)
        #expect(request.method == "POST")
        #expect(request.query["limit"] == "0")
        #expect(request.query["keymap"] == "en-us")
        #expect(request.bodyText == "hello")
    }

    @Test func printRequestsHaveTheirOwnLongTimeoutSession() throws {
        let client = try device.makeClient()
        let print = client.printURLSession.session.configuration
        let ordinary = client.urlSession.session.configuration

        #expect(client.printURLSession !== client.urlSession)
        #expect(print.timeoutIntervalForRequest == GLKVMClient.printRequestTimeout)
        #expect(print.timeoutIntervalForResource == GLKVMClient.printResourceTimeout)
        #expect(ordinary.timeoutIntervalForRequest == 15)
        #expect(ordinary.timeoutIntervalForResource == 30)
    }

    @Test func aLongPasteArrivesWholeAndInOrder() async throws {
        var text = ""
        for line in 1...400 {
            text += "line \(line): naïve café 👍 \r\n"
        }
        text += "end"
        let paste = try #require(input.pasteToRemote(text))
        await paste.value

        #expect(prints.count > 1)
        #expect(prints.allSatisfy { $0.query["limit"] == "0" })
        #expect(prints.allSatisfy { $0.body.count > 0 && $0.bodyText.unicodeScalars.count <= RemotePasteQueue.maxScalarsPerPart })
        #expect(prints.map(\.bodyText).joined() == text)
        #expect(input.isPasteIdle)
    }

    @Test func aSecondPasteWaitsForTheFirst() async throws {
        let latch = Latch()
        device.setHandler { request in
            if request.path == "/api/hid/print", request.bodyText == "first" {
                await latch.wait()
            }
            return .ok()
        }

        let first = try #require(input.pasteToRemote("first"))
        #expect(await waitUntil { prints.count == 1 })
        let second = try #require(input.pasteToRemote("second"))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(prints.map(\.bodyText) == ["first"])

        await latch.open()
        await first.value
        await second.value
        #expect(prints.map(\.bodyText) == ["first", "second"])
    }

    @Test func aDisconnectStopsAPasteMidway() async throws {
        let latch = Latch()
        device.setHandler { request in
            if request.path == "/api/hid/print" {
                await latch.wait()
            }
            return .ok()
        }
        let text = String(repeating: "x", count: RemotePasteQueue.maxScalarsPerPart * 3)

        let paste = try #require(input.pasteToRemote(text))
        let queued = try #require(input.pasteToRemote("queued behind it"))
        #expect(await waitUntil { prints.count == 1 })

        input.setGLKVMClient(nil)
        await paste.value
        await queued.value

        // The part being typed was cancelled (its connection closed, which stops kvmd typing),
        // and nothing after it went out.
        #expect(await waitUntil { device.cancelledRequests.contains { $0.path == "/api/hid/print" } })
        #expect(prints.count == 1)
        #expect(input.isPasteIdle)
        await latch.open()
    }

    @Test func nothingIsPastedWithoutADeviceOrText() throws {
        #expect(input.pasteToRemote("   \n") == nil)
        input.setGLKVMClient(nil)
        #expect(input.pasteToRemote("hello") == nil)
    }
}
