import Foundation
import Vision
import CoreImage
import AppKit
import Combine

@MainActor
class OCRManager: ObservableObject {
    /// Reads the lines of text in a frame already cut down to the part to read. The app reads
    /// with Vision's accurate text request; tests pass a stub, so every way a recognition can end
    /// is driven without Vision. Runs on the OCR queue, never on the main thread.
    typealias LineReader = @Sendable (CVPixelBuffer) throws -> [String]
    /// Finds the lines of text in a whole frame and where each is, for `detectTextRegions`. The
    /// app uses Vision's fast text request; tests pass a stub. Runs on the OCR queue.
    typealias RegionDetector = @Sendable (CVPixelBuffer) throws -> [TextRegion]

    /// True while a click or drag recognition is running. `recognize` sets it and clears it on
    /// the main actor, however the recognition ends.
    @Published private(set) var isProcessing = false
    @Published var lastRecognizedText = ""
    @Published var recognizedRegions: [TextRegion] = []
    
    nonisolated(unsafe) private var textRecognitionRequest: VNRecognizeTextRequest?
    nonisolated(unsafe) private var textObservationRequest: VNRecognizeTextRequest?
    nonisolated(unsafe) private var ocrQueue = DispatchQueue(label: "com.overlook.ocr", qos: .userInitiated)
    nonisolated private let lineReaderOverride: LineReader?
    private let regionDetectorOverride: RegionDetector?
    /// Click and drag recognitions under way; `isProcessing` stays true until the last one ends.
    private(set) var recognitionsInFlight = 0

    /// `lineReader` and `regionDetector` are for tests; the app passes nothing and reads with
    /// Vision.
    init(lineReader: LineReader? = nil, regionDetector: RegionDetector? = nil) {
        lineReaderOverride = lineReader
        regionDetectorOverride = regionDetector
        setupOCRRequests()
    }
    
    private func setupOCRRequests() {
        // No completion handlers: `perform` runs synchronously on the OCR queue and the results
        // are read off the request right after, so each result has one owner.
        textRecognitionRequest = VNRecognizeTextRequest()
        
        // Configure for high accuracy
        textRecognitionRequest?.recognitionLevel = .accurate
        textRecognitionRequest?.usesLanguageCorrection = true
        textRecognitionRequest?.recognitionLanguages = ["en-US", "en-GB"]
        textRecognitionRequest?.automaticallyDetectsLanguage = true
        
        // Setup text observation request for real-time text detection
        textObservationRequest = VNRecognizeTextRequest()
        
        textObservationRequest?.recognitionLevel = .fast
        textObservationRequest?.usesLanguageCorrection = false
        textObservationRequest?.recognitionLanguages = ["en-US", "en-GB"]
        textObservationRequest?.automaticallyDetectsLanguage = true
    }
    
    /// The text in an 800-pixel square around `point` (frame fractions, origin bottom-left).
    /// Throws `OCRError.noTextFound` when there is none.
    func recognizeText(at point: CGPoint, in pixelBuffer: CVPixelBuffer?) async throws -> String {
        guard let pixelBuffer = pixelBuffer else {
            throw OCRError.noVideoFrame
        }

        let frame = PixelBufferBox(pixelBuffer)
        let text = try await recognize { [self] in
            let roi = createRegionOfInterest(around: point, in: frame.pixelBuffer)
            return try readLines(in: cropPixelBuffer(frame.pixelBuffer, to: roi))
        }
        if text.isEmpty {
            throw OCRError.noTextFound
        }
        return text
    }

    /// Runs `read` on the OCR queue and joins the lines it found with spaces.
    private func recognize(_ read: @escaping @Sendable () throws -> [String]) async throws -> String {
        let text = try await recognizeLines(read).joined(separator: " ")
        lastRecognizedText = text
        return text
    }

    /// Runs `read` on the OCR queue and returns the lines it found. Every way out — lines, none,
    /// an error, the caller's task cancelled — clears `isProcessing` on the main actor (once no
    /// other recognition is still running).
    private func recognizeLines(_ read: @escaping @Sendable () throws -> [String]) async throws -> [String] {
        try Task.checkCancellation()
        recognitionsInFlight += 1
        isProcessing = true
        defer {
            recognitionsInFlight -= 1
            isProcessing = recognitionsInFlight > 0
        }

        let lines = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            ocrQueue.async {
                continuation.resume(with: Result { try read() })
            }
        }
        try Task.checkCancellation()
        return lines
    }

    /// The lines of text in `pixelBuffer`, best candidate each, top to bottom and left to right
    /// (`OCRLineLayout`). Every recognition reads through here: the OCR snippet, and OCR mode's
    /// click and drag.
    nonisolated private func readLines(in pixelBuffer: CVPixelBuffer) throws -> [String] {
        if let lineReaderOverride {
            return try lineReaderOverride(pixelBuffer)
        }
        guard let request = textRecognitionRequest else {
            throw OCRError.requestNotInitialized
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])
        let pieces = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { OCRTextPiece(text: $0.string, box: observation.boundingBox) }
        }
        return OCRLineLayout.lines(from: pieces)
    }
    
    /// Every line of text in the frame with where it is, read with Vision's fast request.
    /// Publishes them as `recognizedRegions`.
    func detectTextRegions(in pixelBuffer: CVPixelBuffer?) async throws -> [TextRegion] {
        guard let pixelBuffer = pixelBuffer else {
            throw OCRError.noVideoFrame
        }

        // What the OCR queue runs is taken here, strongly, and never goes through `self`: the
        // work used to reach the request through a weak `self`, and had the manager gone by the
        // time it ran, nothing resumed the continuation and the caller waited forever. Now every
        // way out (regions, none, an error) resumes it exactly once.
        let frame = PixelBufferBox(pixelBuffer)
        let detect = regionDetector()
        let queue = ocrQueue
        let regions = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[TextRegion], Error>) in
            queue.async {
                continuation.resume(with: Result { try detect(frame.pixelBuffer) })
            }
        }
        recognizedRegions = regions
        return regions
    }

    /// The detection the OCR queue runs: the test's stub, or Vision's fast request.
    private func regionDetector() -> RegionDetector {
        if let regionDetectorOverride {
            return regionDetectorOverride
        }
        guard let request = textObservationRequest else {
            return { _ in throw OCRError.requestNotInitialized }
        }
        let box = RequestBox(request)
        return { pixelBuffer in try Self.detectRegions(in: pixelBuffer, with: box.request) }
    }

    nonisolated private static func detectRegions(
        in pixelBuffer: CVPixelBuffer,
        with request: VNRecognizeTextRequest
    ) throws -> [TextRegion] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation -> TextRegion? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextRegion(
                text: candidate.string,
                boundingBox: observation.boundingBox,
                confidence: candidate.confidence
            )
        }
    }

    nonisolated private func createRegionOfInterest(around point: CGPoint, in pixelBuffer: CVPixelBuffer) -> CGRect {
        let bufferSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let clampedX = max(0, min(1, point.x))
        let clampedY = max(0, min(1, point.y))
        
        let minAxis = min(bufferSize.width, bufferSize.height)
        let regionSize: CGFloat = min(800, minAxis)

        let centerX = clampedX * bufferSize.width
        let centerY = clampedY * bufferSize.height

        let rawX = centerX - regionSize / 2
        let rawY = centerY - regionSize / 2

        let x = max(0, min(rawX, bufferSize.width - regionSize))
        let y = max(0, min(rawY, bufferSize.height - regionSize))

        let regionRect = CGRect(x: x, y: y, width: regionSize, height: regionSize)
        
        return regionRect
    }
    
    nonisolated private func cropPixelBuffer(_ pixelBuffer: CVPixelBuffer, to rect: CGRect) -> CVPixelBuffer {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceExtent = ciImage.extent.integral
        let requested = rect.integral
        let clipped = requested.intersection(sourceExtent)

        if clipped.isEmpty {
            return pixelBuffer
        }

        let croppedImage = ciImage
            .cropped(to: clipped)
            .transformed(by: CGAffineTransform(translationX: -clipped.origin.x, y: -clipped.origin.y))
        
        var croppedPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(clipped.width),
            Int(clipped.height),
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            nil,
            &croppedPixelBuffer
        )
        
        guard status == kCVReturnSuccess, let outputBuffer = croppedPixelBuffer else {
            return pixelBuffer
        }
        
        let context = CIContext()
        context.render(croppedImage, to: outputBuffer)
        
        return outputBuffer
    }
    
    // MARK: - Advanced OCR Features
    
    /// The text in `region` (frame fractions, origin bottom-left); empty when there is none.
    func recognizeTextInRegion(_ region: CGRect, in pixelBuffer: CVPixelBuffer?) async throws -> String {
        guard let pixelBuffer = pixelBuffer else {
            throw OCRError.noVideoFrame
        }
        
        let frame = PixelBufferBox(pixelBuffer)
        return try await recognize { [self] in
            let buffer = frame.pixelBuffer
            let bufferSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            let pixelRegion = CGRect(
                x: region.origin.x * bufferSize.width,
                y: region.origin.y * bufferSize.height,
                width: region.size.width * bufferSize.width,
                height: region.size.height * bufferSize.height
            )
            return try readLines(in: cropPixelBuffer(buffer, to: pixelRegion))
        }
    }
    
    /// The lines of text in `region` of the frame, best candidate each, top to bottom and left to
    /// right (`OCRLineLayout`). `region` is in frame fractions with the origin top-left, as the
    /// capture region and the OCR snippet's box are; it is cut from the frame at the frame's own
    /// resolution. Lines may be empty or whitespace only; the caller decides what counts as text.
    func recognizeLines(inTopLeftRegion region: CGRect, of pixelBuffer: CVPixelBuffer?) async throws -> [String] {
        guard let pixelBuffer = pixelBuffer else {
            throw OCRError.noVideoFrame
        }

        let frame = PixelBufferBox(pixelBuffer)
        let lines = try await recognizeLines { [self] in
            let buffer = frame.pixelBuffer
            let width = CGFloat(CVPixelBufferGetWidth(buffer))
            let height = CGFloat(CVPixelBufferGetHeight(buffer))
            // Core Image's origin is bottom-left; the region's is top-left.
            let pixelRegion = CGRect(
                x: region.minX * width,
                y: (1 - region.maxY) * height,
                width: region.width * width,
                height: region.height * height
            )
            return try readLines(in: cropPixelBuffer(buffer, to: pixelRegion))
        }
        lastRecognizedText = lines.joined(separator: "\n")
        return lines
    }

    func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    func getTextAtLocation(_ point: CGPoint, in pixelBuffer: CVPixelBuffer?) async throws -> String {
        // First detect all text regions
        let regions = try await detectTextRegions(in: pixelBuffer)
        
        // Find the region that contains the click point
        for region in regions {
            if region.boundingBox.contains(point) {
                return region.text
            }
        }
        
        // If no region contains the point, perform OCR in a small area around the point
        let smallRegion = CGRect(
            x: max(0, point.x - 0.05),
            y: max(0, point.y - 0.05),
            width: min(0.1, 1.0),
            height: min(0.1, 1.0)
        )
        
        return try await recognizeTextInRegion(smallRegion, in: pixelBuffer)
    }
}

// MARK: - Line order

/// One piece of text Vision recognized and where it is: frame fractions with the origin
/// bottom-left, as Vision gives them.
struct OCRTextPiece: Equatable, Sendable {
    let text: String
    let box: CGRect
}

/// Puts what Vision recognized into reading order. Vision returns its observations in no promised
/// order, and splits one line of the screen into pieces where there is a wide gap (a column of a
/// listing, a right-aligned value).
///
/// Pieces are taken top to bottom by their vertical centres. A piece whose centre is within half
/// a line height of the line being built (the smaller of its own height and the line's) belongs
/// to that line; anything further down starts the next one. Each line's pieces are then put left
/// to right and joined with a single space. Single spaces rather than spaces sized to the gap:
/// sizing needs a character width, which a proportional font does not have and Vision does not
/// report, so the count would often be wrong. Two columns side by side come out row by row, as
/// they are on the screen. Pieces with no text are left out.
enum OCRLineLayout {
    static func lines(from pieces: [OCRTextPiece]) -> [String] {
        let usable = pieces.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.box.height > 0
        }
        // Top first: Vision's y grows upwards.
        let ordered = usable.sorted { a, b in
            a.box.midY != b.box.midY ? a.box.midY > b.box.midY : a.box.minX < b.box.minX
        }

        var rows: [[OCRTextPiece]] = []
        for piece in ordered {
            if let row = rows.last, isOnLine(piece, row) {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }
        return rows.map { row in
            row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
        }
    }

    private static func isOnLine(_ piece: OCRTextPiece, _ row: [OCRTextPiece]) -> Bool {
        let count = CGFloat(row.count)
        let centre = row.map(\.box.midY).reduce(0, +) / count
        let height = row.map(\.box.height).reduce(0, +) / count
        return abs(piece.box.midY - centre) <= min(piece.box.height, height) / 2
    }
}

// MARK: - Supporting Types
struct TextRegion: Identifiable, Codable {
    let id: UUID
    let text: String
    let boundingBox: CGRect
    let confidence: Float

    init(id: UUID = UUID(), text: String, boundingBox: CGRect, confidence: Float) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
    
    var displayText: String {
        return confidence > 0.5 ? text : "[\(text)]"
    }
}

private struct PixelBufferBox: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer

    init(_ pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}

/// Carries a Vision request to the OCR queue, the only place it is performed.
private struct RequestBox: @unchecked Sendable {
    let request: VNRecognizeTextRequest

    init(_ request: VNRecognizeTextRequest) {
        self.request = request
    }
}

/// What a click or drag recognition comes to for the operator: text opens the results sheet;
/// no text (nothing, or only whitespace) and a failure each get a short notice instead of an
/// empty sheet; a cancelled recognition shows nothing.
enum OCROutcome: Equatable {
    case text(String)
    case noText
    case failed(String)
    case cancelled

    init(_ result: Result<String, Error>) {
        switch result {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self = trimmed.isEmpty ? .noText : .text(trimmed)
        case .failure(let error as OCRError) where error == .noTextFound:
            self = .noText
        case .failure(is CancellationError):
            self = .cancelled
        case .failure(let error):
            self = .failed(error.localizedDescription)
        }
    }

    /// The text for the results sheet, or nil when the sheet should stay closed.
    var sheetText: String? {
        if case .text(let text) = self { return text }
        return nil
    }
}

enum OCRError: Error, LocalizedError {
    case noVideoFrame
    case requestNotInitialized
    case noTextFound
    case processingFailed
    
    var errorDescription: String? {
        switch self {
        case .noVideoFrame:
            return "No video frame available for OCR"
        case .requestNotInitialized:
            return "OCR request not properly initialized"
        case .noTextFound:
            return "No text found in the specified region"
        case .processingFailed:
            return "OCR processing failed"
        }
    }
}

// MARK: - OCR Configuration
extension OCRManager {
    func updateRecognitionLanguages(_ languages: [String]) {
        textRecognitionRequest?.recognitionLanguages = languages
        textObservationRequest?.recognitionLanguages = languages
    }
    
    func setRecognitionLevel(_ level: VNRequestTextRecognitionLevel) {
        textRecognitionRequest?.recognitionLevel = level
    }
    
    func enableLanguageCorrection(_ enabled: Bool) {
        textRecognitionRequest?.usesLanguageCorrection = enabled
    }
    
    func setMinimumTextHeight(_ height: Float) {
        textRecognitionRequest?.minimumTextHeight = height
        textObservationRequest?.minimumTextHeight = height
    }
}

// MARK: - Performance Optimization
extension OCRManager {
    func optimizeForRealTime() {
        textRecognitionRequest?.recognitionLevel = .fast
        textObservationRequest?.recognitionLevel = .fast
        textRecognitionRequest?.usesLanguageCorrection = false
        textObservationRequest?.usesLanguageCorrection = false
    }
    
    func optimizeForAccuracy() {
        textRecognitionRequest?.recognitionLevel = .accurate
        textObservationRequest?.recognitionLevel = .accurate
        textRecognitionRequest?.usesLanguageCorrection = true
        textObservationRequest?.usesLanguageCorrection = true
    }
}
