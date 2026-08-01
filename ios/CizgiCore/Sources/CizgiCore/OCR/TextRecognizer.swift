import Foundation
import CoreGraphics

/// One OCR line, in the same frame the marker-detection spike uses: normalized
/// to the image with a top-left origin.
public struct RecognizedLine: Sendable, Equatable, Identifiable {
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
