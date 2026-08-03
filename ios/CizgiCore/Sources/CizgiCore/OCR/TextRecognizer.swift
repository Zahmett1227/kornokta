import Foundation
import CoreGraphics

/// One OCR line, in the same frame the marker-detection spike uses: normalized
/// to the image with a top-left origin.
public struct RecognizedToken: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let confidence: Double
    public let box: CGRect

    public init(id: String, text: String, confidence: Double, box: CGRect) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.box = box
    }

    public init(_ local: LocalToken) {
        self.init(
            id: local.tokenId,
            text: local.text,
            confidence: local.confidence,
            box: CGRect(x: local.x, y: local.y, width: local.width, height: local.height)
        )
    }
}

public struct RecognizedLine: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let confidence: Double
    public let box: CGRect
    /// Vision is never the Turkish text source, but its word geometry lets the
    /// marker detector retain a short underline instead of inflating it to an
    /// entire OCR line.
    public let tokens: [RecognizedToken]

    public init(
        id: String,
        text: String,
        confidence: Double,
        box: CGRect,
        tokens: [RecognizedToken] = []
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.box = box
        self.tokens = tokens
    }

    public init(_ local: LocalLine) {
        self.init(
            id: local.lineId,
            text: local.text,
            confidence: local.confidence,
            box: CGRect(x: local.x, y: local.y, width: local.width, height: local.height),
            tokens: local.tokens.map(RecognizedToken.init)
        )
    }
}

public struct RecognizedPage: Sendable, Equatable {
    public let lines: [RecognizedLine]
    public let elapsed: TimeInterval

    public init(lines: [RecognizedLine], elapsed: TimeInterval) {
        self.lines = lines
        self.elapsed = elapsed
    }

    public var fullText: String {
        lines.map(\.text).joined(separator: "\n")
    }
}

/// On-device OCR. A protocol so the pipeline can be driven by a stub in tests
/// and on machines without Vision.
public protocol TextRecognizing: Sendable {
    func recognize(imageAt url: URL) async throws -> RecognizedPage
}

public enum TextRecognitionError: Error, Sendable {
    case cannotReadImage(URL)
    case recognitionFailed(String)
}
