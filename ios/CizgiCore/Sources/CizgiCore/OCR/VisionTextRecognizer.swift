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
    /// Height of one ordering band, as a fraction of the page.
    static let bandHeight = 0.01

    /// Vision does not promise reading order, so observations are sorted
    /// top-to-bottom then left-to-right for stable line ids.
    ///
    /// The vertical position is quantized into bands instead of compared with
    /// a tolerance. A tolerance comparison is not a strict weak ordering —
    /// `a ≈ b` and `b ≈ c` can hold while `a < c` does too — and `sorted(by:)`
    /// given such a predicate returns an arbitrary permutation, which on a
    /// dense page scrambles the transcript. Rounding to a band is transitive.
    ///
    /// Kept identical to `AppleVisionSpike.VisionOCR.inReadingOrder`: the Faz 0
    /// measurement is only meaningful if the app orders lines the same way.
    static func inReadingOrder(
        _ observations: [VNRecognizedTextObservation]
    ) -> [VNRecognizedTextObservation] {
        func band(_ observation: VNRecognizedTextObservation) -> Int {
            // Flip to a top-left origin first, so band 0 is the top of the page.
            Int(((1.0 - observation.boundingBox.maxY) / bandHeight).rounded())
        }
        return observations.sorted { a, b in
            let bandA = band(a), bandB = band(b)
            if bandA != bandB { return bandA < bandB }
            return a.boundingBox.minX < b.boundingBox.minX
        }
    }

    /// Languages this device can actually recognize (§10.1). Vision silently
    /// drops a requested language it does not support.
    public static func supportedLanguages() throws -> [String] {
        try VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .accurate,
            revision: VNRecognizeTextRequest.currentRevision
        )
    }

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

        let ordered = Self.inReadingOrder(request.results ?? [])

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
