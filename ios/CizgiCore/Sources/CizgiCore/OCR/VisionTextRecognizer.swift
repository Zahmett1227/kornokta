#if canImport(Vision)
import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Apple Vision OCR (ANA-PLAN §10.1).
///
/// This is the fast local pass: it drives the live preview and lets a capture
/// finish with no network. It is explicitly **not** the final source of truth —
/// Google Document AI and the model reconciliation decide that (§10.2, §10.3).
public struct VisionTextRecognizer: TextRecognizing {
    public var languages: [String]
    /// Off by default. Language correction rewrites text towards ordinary
    /// vocabulary, which is the silent "fix" §0.5 forbids — it can turn a drug
    /// name or a dose into a common word before we compare it to the source.
    public var usesLanguageCorrection: Bool

    public init(languages: [String] = ["tr-TR", "en-US"], usesLanguageCorrection: Bool = false) {
        self.languages = languages
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    public func recognize(imageAt url: URL) async throws -> RecognizedPage {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw TextRecognitionError.cannotReadImage(url)
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = usesLanguageCorrection

        let started = Date()
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            throw TextRecognitionError.recognitionFailed(String(describing: error))
        }
        let elapsed = Date().timeIntervalSince(started)

        let observations = request.results ?? []
        // Vision does not promise reading order; sort top-to-bottom then
        // left-to-right so line ids are stable across runs.
        let ordered = observations.sorted { a, b in
            let ay = 1 - a.boundingBox.maxY
            let by = 1 - b.boundingBox.maxY
            if abs(ay - by) > 0.005 { return ay < by }
            return a.boundingBox.minX < b.boundingBox.minX
        }

        let lines = ordered.enumerated().compactMap { index, observation -> RecognizedLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return RecognizedLine(
                id: String(format: "line_%02d", index),
                text: candidate.string,
                confidence: Double(candidate.confidence),
                // Vision's origin is bottom-left; flip to top-left.
                box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            )
        }

        return RecognizedPage(lines: lines, elapsed: elapsed)
    }
}
#endif
