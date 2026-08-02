import Foundation
import Vision
import ImageIO

enum VisionOCRError: Error, CustomStringConvertible {
    case cannotReadImage(URL)

    var description: String {
        switch self {
        case .cannotReadImage(let url):
            return "Görüntü okunamadı: \(url.path)"
        }
    }
}

struct VisionOCR {
    /// Height of one ordering band, as a fraction of the page.
    static let bandHeight = 0.01

    /// Vision returns observations in no guaranteed reading order, so they are
    /// sorted top-to-bottom then left-to-right for stable `lineId` numbering.
    ///
    /// The vertical position is **quantized into bands** rather than compared
    /// with a tolerance. `abs(ay - by) > epsilon` is not a strict weak
    /// ordering: `a ≈ b` and `b ≈ c` can hold while `a < c` does too, and
    /// `sorted(by:)` given such a predicate returns an arbitrary permutation.
    /// On a dense page that scrambles the whole transcript. Rounding to a band
    /// is transitive, so the sort is well-defined.
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

    /// Languages this device can actually recognize. Vision silently ignores a
    /// requested language it does not support, which looks like poor accuracy
    /// rather than an unsupported language — §0.5 says that kind of silent
    /// substitution must be surfaced, not hidden.
    static func supportedLanguages() throws -> [String] {
        try VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .accurate,
            revision: VNRecognizeTextRequest.currentRevision
        )
    }

    var languages: [String]
    /// Off by default. Language correction rewrites text towards ordinary
    /// vocabulary, which is exactly the silent "fix" ANA-PLAN §0.5 forbids —
    /// it would quietly turn a drug name or dose into a common word before we
    /// ever get to compare it against the source.
    var usesLanguageCorrection: Bool

    func recognize(imageAt url: URL) throws -> OCRPage {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw VisionOCRError.cannotReadImage(url)
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = usesLanguageCorrection

        let started = Date()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

        let observations = request.results ?? []
        let width = cgImage.width
        let height = cgImage.height

        let ordered = Self.inReadingOrder(observations)

        let lines: [OCRLine] = ordered.enumerated().compactMap { index, observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return OCRLine(
                lineId: String(format: "line_%02d", index),
                text: candidate.string,
                confidence: Double(candidate.confidence),
                x: Double(box.minX),
                // Vision's origin is bottom-left; flip to top-left.
                y: Double(1.0 - box.maxY),
                width: Double(box.width),
                height: Double(box.height)
            )
        }

        return OCRPage(
            imagePath: url.path,
            imageWidth: width,
            imageHeight: height,
            recognitionLanguages: languages,
            usesLanguageCorrection: usesLanguageCorrection,
            revision: Int(request.revision),
            elapsedMs: elapsedMs,
            lines: lines
        )
    }
}
