import Foundation

/// One OCR text line, in the shape the Python evaluation tools consume.
///
/// `boundingBox` is normalized to the image (0–1) with a **top-left** origin,
/// converted from Vision's bottom-left convention so it lines up with the
/// marker-detection spike's `LineBox`.
struct OCRLine: Codable {
    let lineId: String
    let text: String
    let confidence: Double
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct OCRPage: Codable {
    let imagePath: String
    let imageWidth: Int
    let imageHeight: Int
    let recognitionLanguages: [String]
    let usesLanguageCorrection: Bool
    let revision: Int
    let elapsedMs: Int
    let lines: [OCRLine]

    /// Full transcription, one line per detected line, in reading order.
    var fullText: String { lines.map(\.text).joined(separator: "\n") }
}

struct OCRRun: Codable {
    let generatedBy: String
    /// What the run asked Vision for.
    let requestedLanguages: [String]
    /// What this device can actually recognize.
    let supportedLanguages: [String]
    /// Requested but unavailable — Vision drops these without complaining, so
    /// the report has to carry the caveat or the numbers read as pure accuracy.
    let unsupportedLanguages: [String]
    let pages: [OCRPage]
}
