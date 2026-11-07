import Foundation

/// Types pasted text into the target through the device's `hid/print`, one paste at a time.
///
/// What the endpoint does shapes this:
/// - It cuts the text to `limit` code points, 1024 unless told otherwise. `hidPrint` sends
///   `limit=0`, which turns that off.
/// - It answers only once the device has typed the text, a few milliseconds per key event, and
///   it stops typing when the request's connection closes. A long paste sent as one request
///   would need a timeout of many minutes, so it is split into parts of at most
///   `maxScalarsPerPart` code points, each a request of its own over the client's long-timeout
///   session. A request that does time out then costs one part, not the rest of the paste.
/// - Parts never split a character (`Character`, a grapheme cluster): an emoji sequence, a letter
///   with its combining marks, or a CRLF line end stays whole.
///
/// Pastes run one after another, and the parts of each in order, so two quick ⌘Vs cannot
/// interleave on the target. `cancelAll` stops them: the request under way is cancelled, which
/// closes its connection and so stops the device typing, and no later part is sent.
@MainActor
final class RemotePasteQueue {
    /// kvmd waits 5 ms before each key event and a character takes two or more events, so a part
    /// this size is seconds of typing: well inside `GLKVMClient.printRequestTimeout`, and large
    /// enough that a long paste is not slowed by a request per handful of characters.
    nonisolated static let maxScalarsPerPart = 512

    private var tail: Task<Void, Never>?
    private var pastes: [UUID: Task<Void, Never>] = [:]

    /// True when no paste is queued or under way.
    var isIdle: Bool { pastes.isEmpty }

    /// Queues `text` to be typed after any paste already queued. Returns the paste's task, which
    /// ends when the paste is done, has failed, or was stopped.
    @discardableResult
    func enqueue(_ text: String, to client: GLKVMClient, log: SessionLog) -> Task<Void, Never> {
        let parts = Self.parts(of: text)
        let characterCount = text.count
        let previous = tail
        let id = UUID()
        let task = Task { [weak self] in
            await previous?.value
            await Self.type(parts, characterCount: characterCount, to: client, log: log)
            self?.pastes[id] = nil
        }
        pastes[id] = task
        tail = task
        return task
    }

    /// Stops every queued paste and the one under way.
    func cancelAll() {
        for task in pastes.values {
            task.cancel()
        }
        pastes.removeAll()
        tail = nil
    }

    private static func type(_ parts: [String], characterCount: Int, to client: GLKVMClient, log: SessionLog) async {
        guard !Task.isCancelled else { return }
        let keymap = try? await client.getSystemConfig().keymap
        log.info(.hid, parts.count > 1
            ? "Pasting \(characterCount) characters in \(parts.count) parts"
            : "Pasting \(characterCount) characters")
        for (index, part) in parts.enumerated() {
            guard !Task.isCancelled else {
                log.notice(.hid, "Paste stopped after part \(index) of \(parts.count)")
                return
            }
            do {
                try await client.hidPrint(text: part, keymap: keymap)
            } catch {
                if Task.isCancelled {
                    log.notice(.hid, "Paste stopped during part \(index + 1) of \(parts.count)")
                } else {
                    log.warning(.hid, "Paste to remote failed at part \(index + 1) of \(parts.count): \(error.localizedDescription)")
                }
                return
            }
        }
    }

    /// Splits `text` into parts of at most `maxScalars` code points (kvmd counts code points),
    /// breaking only between characters. A single character longer than that is a part of its own.
    nonisolated static func parts(of text: String, maxScalars: Int = maxScalarsPerPart) -> [String] {
        var parts: [String] = []
        var current = ""
        var currentScalars = 0
        for character in text {
            let scalars = character.unicodeScalars.count
            if currentScalars > 0, currentScalars + scalars > maxScalars {
                parts.append(current)
                current = ""
                currentScalars = 0
            }
            current.append(character)
            currentScalars += scalars
        }
        if !current.isEmpty {
            parts.append(current)
        }
        return parts
    }
}
