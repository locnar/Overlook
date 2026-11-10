import Foundation
import Testing
@testable import Overlook

/// Messages as Janus pushes them over the signaling socket, parsed the way the listener parses
/// them, so numbers arrive as `NSNumber` just as they do from the wire.
private enum Recorded {
    static let session = 5_550_001
    static let video = 7_001
    static let audio = 7_002
    /// The previous connection's handles, from before a reconnect.
    static let oldVideo = 6_001
    static let oldAudio = 6_002

    static func parse(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }

    static func trickle(from sender: Int) -> [String: Any] {
        parse(#"""
        {"janus":"trickle","session_id":\#(session),"sender":\#(sender),
         "candidate":{"sdpMid":"0","sdpMLineIndex":0,
                      "candidate":"candidate:1 1 udp 2015363327 192.168.0.131 40123 typ host"}}
        """#)
    }

    static func trickleCompleted(from sender: Int) -> [String: Any] {
        parse(#"{"janus":"trickle","session_id":\#(session),"sender":\#(sender),"candidate":{"completed":true}}"#)
    }

    static let trickleWithoutSender = parse(#"""
    {"janus":"trickle","session_id":\#(session),
     "candidate":{"sdpMid":"0","sdpMLineIndex":0,"candidate":"candidate:1 1 udp 1 10.0.0.1 1 typ host"}}
    """#)

    static func offer(from sender: Int) -> [String: Any] {
        parse(#"""
        {"janus":"event","session_id":\#(session),"sender":\#(sender),"transaction":"0a1b2c",
         "plugindata":{"plugin":"janus.plugin.ustreamer","data":{"result":{"status":"started"}}},
         "jsep":{"type":"offer","sdp":"v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"}}
        """#)
    }

    static func event(from sender: Int) -> [String: Any] {
        parse(#"""
        {"janus":"event","session_id":\#(session),"sender":\#(sender),
         "plugindata":{"plugin":"janus.plugin.ustreamer","data":{"result":{"status":"started"}}}}
        """#)
    }

    static func notification(_ type: String, from sender: Int) -> [String: Any] {
        parse(#"{"janus":"\#(type)","session_id":\#(session),"sender":\#(sender)}"#)
    }

    static let keepaliveAck = parse(#"{"janus":"ack","session_id":\#(session),"transaction":"9f8e7d"}"#)
    static let timeout = parse(#"{"janus":"timeout","session_id":\#(session)}"#)
    static let hangupWithoutSender = parse(#"{"janus":"hangup","session_id":\#(session),"reason":"Close PC"}"#)
    static let error = parse(#"{"janus":"error","transaction":"1234","error":{"code":458,"reason":"No such session"}}"#)
}

/// Which of the current connection's handles a pushed message came from.
@Suite("Janus message senders")
struct JanusSenderFilterTests {
    private func verdict(
        _ message: [String: Any],
        _ filter: inout JanusSenderFilter,
        video: Int? = Recorded.video,
        audio: Int? = Recorded.audio
    ) -> JanusSenderFilter.Verdict {
        filter.verdict(for: message, videoHandle: video, audioHandle: audio)
    }

    @Test func aCandidateFromTheVideoHandleGoesToTheVideoLeg() {
        var filter = JanusSenderFilter()
        #expect(verdict(Recorded.trickle(from: Recorded.video), &filter) == .leg(.video))
        #expect(verdict(Recorded.trickleCompleted(from: Recorded.video), &filter) == .leg(.video))
    }

    @Test func aCandidateFromTheAudioHandleGoesToTheAudioLeg() {
        var filter = JanusSenderFilter()
        #expect(verdict(Recorded.trickle(from: Recorded.audio), &filter) == .leg(.audio))
    }

    @Test func offersGoToTheLegWhoseHandleSentThem() {
        var filter = JanusSenderFilter()
        #expect(verdict(Recorded.offer(from: Recorded.video), &filter) == .leg(.video))
        #expect(verdict(Recorded.offer(from: Recorded.audio), &filter) == .leg(.audio))
    }

    @Test func aCandidateFromAnUnknownHandleIsDroppedAndReportedOnce() {
        // The bug this guards: anything not from the audio handle was applied to the video peer.
        var filter = JanusSenderFilter()
        #expect(verdict(Recorded.trickle(from: 9_999), &filter) == .drop(sender: 9_999, isFirst: true))
        #expect(verdict(Recorded.trickle(from: 9_999), &filter) == .drop(sender: 9_999, isFirst: false))
        #expect(verdict(Recorded.trickle(from: 9_998), &filter) == .drop(sender: 9_998, isFirst: true))
    }

    @Test func anOfferFromAnUnknownHandleIsDropped() {
        var filter = JanusSenderFilter()
        #expect(verdict(Recorded.offer(from: 9_999), &filter) == .drop(sender: 9_999, isFirst: true))
    }

    @Test func aCandidateOrOfferThatNamesNoHandleIsDropped() {
        var filter = JanusSenderFilter()
        #expect(verdict(Recorded.trickleWithoutSender, &filter) == .drop(sender: nil, isFirst: true))
        var offer = Recorded.offer(from: Recorded.video)
        offer["sender"] = nil
        #expect(verdict(offer, &filter) == .drop(sender: nil, isFirst: false))
    }

    @Test func thePreviousConnectionsHandlesAreDroppedAfterAReconnect() {
        var filter = JanusSenderFilter()
        #expect(verdict(Recorded.trickle(from: Recorded.oldVideo), &filter, video: Recorded.oldVideo, audio: Recorded.oldAudio)
            == .leg(.video))

        filter.reset()  // the teardown a reconnect starts with
        for message in [
            Recorded.trickle(from: Recorded.oldVideo),
            Recorded.offer(from: Recorded.oldAudio),
            Recorded.notification("webrtcup", from: Recorded.oldVideo),
            Recorded.notification("hangup", from: Recorded.oldVideo),
        ] {
            guard case .drop = verdict(message, &filter) else {
                Issue.record("\(message) from the previous connection was not dropped")
                continue
            }
        }
        #expect(verdict(Recorded.trickle(from: Recorded.video), &filter) == .leg(.video))
    }

    @Test func nothingNamingAHandleIsTakenBeforeTheHandlesAreKnown() {
        var filter = JanusSenderFilter()
        #expect(verdict(Recorded.trickle(from: Recorded.video), &filter, video: nil, audio: nil)
            == .drop(sender: Recorded.video, isFirst: true))
    }

    @Test func sessionLevelMessagesAreStillHandled() {
        var filter = JanusSenderFilter()
        #expect(verdict(Recorded.keepaliveAck, &filter) == .session)
        #expect(verdict(Recorded.timeout, &filter) == .session)
        #expect(verdict(Recorded.hangupWithoutSender, &filter) == .session)
        #expect(verdict(Recorded.error, &filter) == .session)
        #expect(verdict(Recorded.parse(#"{"janus":"keepalive","session_id":1}"#), &filter) == .session)
    }

    @Test func handleNotificationsFromCurrentHandlesAreStillHandled() {
        var filter = JanusSenderFilter()
        #expect(verdict(Recorded.notification("webrtcup", from: Recorded.video), &filter) == .leg(.video))
        #expect(verdict(Recorded.notification("hangup", from: Recorded.video), &filter) == .leg(.video))
        #expect(verdict(Recorded.notification("detached", from: Recorded.audio), &filter) == .leg(.audio))
        #expect(verdict(Recorded.notification("media", from: Recorded.audio), &filter) == .leg(.audio))
        #expect(verdict(Recorded.event(from: Recorded.audio), &filter) == .leg(.audio))
    }

    @Test func droppedMessagesAreNamedForTheLog() {
        #expect(JanusSenderFilter.describe(Recorded.trickle(from: 1)) == "trickle")
        #expect(JanusSenderFilter.describe(Recorded.offer(from: 1)) == "event with offer")
        #expect(JanusSenderFilter.describe(Recorded.notification("webrtcup", from: 1)) == "webrtcup")
    }
}

/// The filter as the manager applies it: strays are dropped and logged once, and session-level
/// messages still reach their handling. No connect runs, so the manager has no handles and no
/// peers, and nothing reaches the network.
@MainActor
@Suite("Janus message senders through the manager")
struct ManagerJanusSenderTests {
    let scratch = ScratchDefaults()
    let log = SessionLog(destination: .inMemory())
    let manager: WebRTCManager

    init() {
        manager = WebRTCManager(audioPreferences: AudioPreferences(defaults: scratch.defaults), log: log)
    }

    private func count(_ text: String) -> Int {
        log.store.events(in: .allDevices).filter { $0.message.contains(text) }.count
    }

    @Test func strayCandidatesAndOffersAreDroppedAndLoggedOncePerSender() async {
        await manager.handleJanusMessage(Recorded.trickle(from: 9_999))
        await manager.handleJanusMessage(Recorded.trickle(from: 9_999))
        await manager.handleJanusMessage(Recorded.offer(from: 9_999))
        await manager.handleJanusMessage(Recorded.offer(from: 8_888))

        #expect(await waitUntil { count("from unknown sender 8888") == 1 })
        #expect(count("Dropped Janus trickle from unknown sender 9999") == 1)
        #expect(count("from unknown sender 9999") == 1)
        #expect(count("Dropped Janus event with offer from unknown sender 8888") == 1)
    }

    @Test func aStrayHangupDoesNotReconnect() async throws {
        await manager.handleJanusMessage(Recorded.notification("hangup", from: Recorded.oldVideo))
        #expect(await waitUntil { count("unknown sender \(Recorded.oldVideo)") == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(count("Janus hangup on") == 0)
        #expect(count("Reconnect") == 0)
    }

    @Test func aSessionTimeoutIsStillHandled() async {
        await manager.handleJanusMessage(Recorded.timeout)
        #expect(await waitUntil { count("Janus session timed out") == 1 })
        // The reconnect path is asked; with no device to reconnect to it stands down.
        #expect(await waitUntil { count("Reconnect suppressed (Signaling session timed out)") == 1 })
        #expect(count("unknown sender") == 0)
    }

    @Test func aHangupThatNamesNoHandleIsStillHandled() async {
        await manager.handleJanusMessage(Recorded.hangupWithoutSender)
        #expect(await waitUntil { count("Janus hangup on") == 1 })
        #expect(await waitUntil { count("Reconnect suppressed (Server hung up: Close PC)") == 1 })
        #expect(count("unknown sender") == 0)
    }
}
