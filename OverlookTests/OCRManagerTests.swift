import CoreVideo
import Foundation
import Testing
@testable import Overlook

/// How a click or drag recognition ends, with a stub reading the lines instead of Vision. Each
/// way out — text, no text, an error, cancellation — leaves `isProcessing` false.
@MainActor
@Suite("OCR manager")
struct OCRManagerTests {
    /// A blank 64×64 frame; the stub reader never looks at it.
    static func frame() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        #expect(status == kCVReturnSuccess)
        return try #require(buffer)
    }

    /// Holds the stub reader on the OCR queue until the test lets it go.
    final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var entered = 0

        var timesEntered: Int { lock.withLock { entered } }

        func pass() {
            lock.withLock { entered += 1 }
            _ = semaphore.wait(timeout: .now() + 5)
        }

        func open() {
            semaphore.signal()
        }
    }

    @Test func textFoundIsReturnedAndProcessingEnds() async throws {
        let ocr = OCRManager(lineReader: { _ in ["Hello", "world"] })
        let text = try await ocr.recognizeText(at: CGPoint(x: 0.5, y: 0.5), in: try Self.frame())
        #expect(text == "Hello world")
        #expect(ocr.lastRecognizedText == "Hello world")
        #expect(ocr.isProcessing == false)
    }

    @Test func noTextAtAPointThrowsAndProcessingEnds() async throws {
        let ocr = OCRManager(lineReader: { _ in [] })
        await #expect(throws: OCRError.noTextFound) {
            try await ocr.recognizeText(at: CGPoint(x: 0.5, y: 0.5), in: try Self.frame())
        }
        #expect(ocr.isProcessing == false)
    }

    @Test func noTextInARegionProcessingEnds() async throws {
        let ocr = OCRManager(lineReader: { _ in [] })
        _ = try? await ocr.recognizeTextInRegion(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), in: try Self.frame())
        #expect(ocr.isProcessing == false)
    }

    @Test func textInARegionIsReturnedAndProcessingEnds() async throws {
        let ocr = OCRManager(lineReader: { _ in ["ls", "-la"] })
        let text = try await ocr.recognizeTextInRegion(CGRect(x: 0, y: 0, width: 1, height: 1), in: try Self.frame())
        #expect(text == "ls -la")
        #expect(ocr.isProcessing == false)
    }

    @Test func aReaderErrorIsPassedOnAndProcessingEnds() async throws {
        let ocr = OCRManager(lineReader: { _ in throw TestError(name: "vision") })
        await #expect(throws: TestError(name: "vision")) {
            try await ocr.recognizeText(at: .zero, in: try Self.frame())
        }
        #expect(ocr.isProcessing == false)
        await #expect(throws: TestError(name: "vision")) {
            try await ocr.recognizeTextInRegion(CGRect(x: 0, y: 0, width: 1, height: 1), in: try Self.frame())
        }
        #expect(ocr.isProcessing == false)
    }

    @Test func noFrameThrowsWithoutStartingProcessing() async {
        let ocr = OCRManager(lineReader: { _ in ["unused"] })
        await #expect(throws: OCRError.noVideoFrame) {
            try await ocr.recognizeText(at: .zero, in: nil)
        }
        #expect(ocr.isProcessing == false)
    }

    @Test func processingIsTrueOnlyWhileTheReaderRuns() async throws {
        let gate = Gate()
        let ocr = OCRManager(lineReader: { _ in gate.pass(); return ["done"] })
        let frame = try Self.frame()
        let task = Task { try await ocr.recognizeText(at: .zero, in: frame) }

        #expect(await waitUntil { gate.timesEntered == 1 })
        #expect(ocr.isProcessing == true)

        gate.open()
        #expect(try await task.value == "done")
        #expect(ocr.isProcessing == false)
    }

    @Test func cancellingTheCallerEndsProcessing() async throws {
        let gate = Gate()
        let ocr = OCRManager(lineReader: { _ in gate.pass(); return ["too late"] })
        let frame = try Self.frame()
        let task = Task { try await ocr.recognizeText(at: .zero, in: frame) }

        #expect(await waitUntil { gate.timesEntered == 1 })
        task.cancel()
        gate.open()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(ocr.isProcessing == false)
        #expect(ocr.lastRecognizedText == "")
    }

    /// Two recognitions at once (a click while a drag is being read): processing lasts until the
    /// second one ends, not just the first.
    @Test func processingLastsUntilTheLastRecognitionEnds() async throws {
        let gate = Gate()
        let ocr = OCRManager(lineReader: { _ in gate.pass(); return ["text"] })
        let frame = try Self.frame()
        let first = Task { try await ocr.recognizeText(at: .zero, in: frame) }
        #expect(await waitUntil { gate.timesEntered == 1 })
        let second = Task { try await ocr.recognizeTextInRegion(CGRect(x: 0, y: 0, width: 1, height: 1), in: frame) }
        #expect(await waitUntil { ocr.recognitionsInFlight == 2 })

        gate.open()
        _ = try await first.value
        #expect(await waitUntil { gate.timesEntered == 2 })
        #expect(ocr.isProcessing == true)

        gate.open()
        _ = try await second.value
        #expect(ocr.isProcessing == false)
    }
}

/// Whether a recognition opens the results sheet or shows a notice. No text — nothing, only
/// whitespace, or `noTextFound` — never opens an empty sheet.
@MainActor
@Suite("OCR outcome")
struct OCROutcomeTests {
    let scratch = ScratchDefaults()
    let capture: CaptureManager

    init() {
        let catalog = Fixtures.catalog(scratch)
        capture = CaptureManager(
            webRTCManager: WebRTCManager(),
            connection: SessionConnection(catalog: catalog),
            defaults: scratch.defaults
        )
    }

    @Test func textOpensTheSheetTrimmed() {
        let outcome = OCROutcome(.success("  ls -la \n"))
        #expect(outcome == .text("ls -la"))
        #expect(outcome.sheetText == "ls -la")
    }

    @Test(arguments: ["", " ", "\n", " \t\n  "])
    func blankTextIsNoText(text: String) {
        let outcome = OCROutcome(.success(text))
        #expect(outcome == .noText)
        #expect(outcome.sheetText == nil)
    }

    @Test func noTextFoundIsNoText() {
        #expect(OCROutcome(.failure(OCRError.noTextFound)) == .noText)
    }

    @Test func otherErrorsAreFailures() {
        #expect(OCROutcome(.failure(OCRError.noVideoFrame)) == .failed("No video frame available for OCR"))
        #expect(OCROutcome(.failure(OCRError.noVideoFrame)).sheetText == nil)
    }

    @Test func cancellationIsQuiet() {
        #expect(OCROutcome(.failure(CancellationError())) == .cancelled)
    }

    @Test func noTextShowsAPlainNotice() throws {
        capture.showOCRNotice(for: .noText)
        let notice = try #require(capture.notice)
        #expect(notice.title == "No text found")
        #expect(notice.detail == nil)
        #expect(notice.fileURL == nil)
        #expect(notice.isError == false)
        #expect(notice.systemImage == "text.viewfinder")
    }

    @Test func aFailureShowsWhy() throws {
        capture.showOCRNotice(for: .failed("No video frame available for OCR"))
        let notice = try #require(capture.notice)
        #expect(notice.title == "Text recognition failed")
        #expect(notice.detail == "No video frame available for OCR")
        #expect(notice.isError == true)
    }

    @Test func textAndCancellationShowNoNotice() {
        capture.showOCRNotice(for: .text("hello"))
        #expect(capture.notice == nil)
        capture.showOCRNotice(for: .cancelled)
        #expect(capture.notice == nil)
    }

    /// End to end with a stub reader: a drag over whitespace-only text comes to a notice.
    @Test func aDragOverBlankTextComesToNoText() async throws {
        let ocr = OCRManager(lineReader: { _ in ["  ", "\t"] })
        let text = try await ocr.recognizeTextInRegion(CGRect(x: 0, y: 0, width: 1, height: 1), in: try OCRManagerTests.frame())
        #expect(OCROutcome(.success(text)) == .noText)
    }

    @Test func aClickOverNothingComesToNoText() async throws {
        let ocr = OCRManager(lineReader: { _ in [] })
        let outcome: OCROutcome
        do {
            outcome = OCROutcome(.success(try await ocr.recognizeText(at: .zero, in: try OCRManagerTests.frame())))
        } catch {
            outcome = OCROutcome(.failure(error))
        }
        #expect(outcome == .noText)
    }
}

/// Whole-frame text detection with a stub detector instead of Vision. Every way out resumes the
/// caller once.
@MainActor
@Suite("OCR text detection")
struct OCRTextDetectionTests {
    nonisolated static let regions = [
        TextRegion(text: "login:", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.05), confidence: 0.9),
        TextRegion(text: "root", boundingBox: CGRect(x: 0.3, y: 0.8, width: 0.1, height: 0.05), confidence: 0.8),
    ]

    @Test func regionsFoundAreReturnedAndPublished() async throws {
        let ocr = OCRManager(regionDetector: { _ in Self.regions })
        let found = try await ocr.detectTextRegions(in: try OCRManagerTests.frame())
        #expect(found.map(\.text) == ["login:", "root"])
        #expect(ocr.recognizedRegions.map(\.text) == ["login:", "root"])
    }

    @Test func noRegionsIsAnEmptyResult() async throws {
        let ocr = OCRManager(regionDetector: { _ in [] })
        #expect(try await ocr.detectTextRegions(in: try OCRManagerTests.frame()).isEmpty)
        #expect(ocr.recognizedRegions.isEmpty)
    }

    @Test func aDetectorErrorReachesTheCaller() async throws {
        let ocr = OCRManager(regionDetector: { _ in throw OCRError.processingFailed })
        await #expect(throws: OCRError.processingFailed) {
            try await ocr.detectTextRegions(in: try OCRManagerTests.frame())
        }
    }

    @Test func noFrameThrowsWithoutDetecting() async {
        let ocr = OCRManager(regionDetector: { _ in
            Issue.record("Detected without a frame")
            return []
        })
        await #expect(throws: OCRError.noVideoFrame) {
            try await ocr.detectTextRegions(in: nil)
        }
    }

    /// The test lets go of its only reference while the detection runs on the OCR queue. The call
    /// still comes back with the regions (the queue's work holds what it needs, not the manager),
    /// and once it has, the manager is freed: nothing on the queue kept it.
    @Test(.timeLimit(.minutes(1)))
    func aDetectionFinishesWhenTheCallerLetsGoOfTheManager() async throws {
        let gate = OCRManagerTests.Gate()
        let frame = try OCRManagerTests.frame()
        weak var released: OCRManager?
        var ocr: OCRManager? = OCRManager(regionDetector: { _ in
            gate.pass()
            return Self.regions
        })
        released = ocr
        let call = Task { [weak ocr] () -> [TextRegion]? in
            try await ocr?.detectTextRegions(in: frame)
        }
        while gate.timesEntered == 0 {
            await Task.yield()
        }
        ocr = nil
        gate.open()
        let found = try await call.value
        #expect(found.map { $0.map(\.text) } == ["login:", "root"])
        #expect(await waitUntil { released == nil })
    }
}
