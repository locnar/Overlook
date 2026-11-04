import Foundation
import Testing
@testable import Overlook

/// How ICE callbacks are matched to the video and audio peer connections, including the ones that
/// are handled after a teardown has let go of their peer. Stand-in objects take the place of real
/// peer connections, so nothing here starts WebRTC or touches the network.
@Suite("Peer connection roles")
struct PeerConnectionRolesTests {
    final class FakePeer {}

    @Test func liveCallbacksAreMatchedToTheirPeer() {
        var roles = PeerConnectionRoles<FakePeer>()
        let video = FakePeer()
        let audio = FakePeer()
        roles.register(video, as: .video)
        roles.register(audio, as: .audio)

        #expect(roles.disposition(for: video, isClosed: false) == .live(.video))
        #expect(roles.disposition(for: audio, isClosed: false) == .live(.audio))
    }

    @Test func everyTransitionDuringASessionIsKept() {
        // A network change takes ICE through disconnected, checking and connected again; each
        // one is a line in the log, including a state the peer has been in before.
        var roles = PeerConnectionRoles<FakePeer>()
        let video = FakePeer()
        roles.register(video, as: .video)

        for _ in ["checking", "connected", "disconnected", "checking", "connected"] {
            #expect(roles.disposition(for: video, isClosed: false) == .live(.video))
        }
    }

    @Test func eachPeerClosesOnceUnderItsOwnRole() {
        // The bug this guards: the video peer's close was handled after teardown cleared the
        // manager's references, and was logged as a second audio close.
        var roles = PeerConnectionRoles<FakePeer>()
        let video = FakePeer()
        let audio = FakePeer()
        roles.register(video, as: .video)
        roles.register(audio, as: .audio)

        roles.retireAll()

        #expect(roles.disposition(for: audio, isClosed: true) == .closed(.audio))
        #expect(roles.disposition(for: video, isClosed: true) == .closed(.video))
        #expect(roles.disposition(for: audio, isClosed: true) == .ignore)
        #expect(roles.disposition(for: video, isClosed: true) == .ignore)
        #expect(roles.count == 0)
    }

    @Test func aTornDownPeerSaysNothingButItsClose() {
        // A state change that raced the teardown would otherwise be read as part of the next
        // connection; it must not read as the new video peer either.
        var roles = PeerConnectionRoles<FakePeer>()
        let oldVideo = FakePeer()
        roles.register(oldVideo, as: .video)
        roles.retireAll()
        let newVideo = FakePeer()
        roles.register(newVideo, as: .video)

        #expect(roles.disposition(for: oldVideo, isClosed: false) == .ignore)
        #expect(roles.disposition(for: newVideo, isClosed: false) == .live(.video))
        #expect(roles.disposition(for: oldVideo, isClosed: true) == .closed(.video))
        #expect(roles.disposition(for: newVideo, isClosed: false) == .live(.video))
    }

    @Test func anUnknownPeerIsIgnored() {
        var roles = PeerConnectionRoles<FakePeer>()
        roles.register(FakePeer(), as: .video)

        #expect(roles.disposition(for: FakePeer(), isClosed: false) == .ignore)
        #expect(roles.disposition(for: FakePeer(), isClosed: true) == .ignore)
    }

    @Test func aCloseThatNeverComesIsLetGoTwoTeardownsLater() {
        // Torn-down peers are held so their address is not reused by a new peer before their
        // close is handled, but not for good if that close never arrives.
        var roles = PeerConnectionRoles<FakePeer>()
        weak var released: FakePeer?
        do {
            let peer = FakePeer()
            released = peer
            roles.register(peer, as: .audio)
        }
        roles.retireAll()
        #expect(released != nil)

        // Kept through the next teardown, whose own peers' closes may still be on the way.
        roles.register(FakePeer(), as: .video)
        roles.retireAll()
        #expect(released != nil)

        roles.retireAll()
        #expect(released == nil)
        // Only the peer from the teardown before this one is still held.
        #expect(roles.count == 1)
    }
}
