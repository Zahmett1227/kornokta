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

        // Vision returns observations in no guaranteed reading order; sort
        // top-to-bottom then left-to-right so lineId numbering is stable
        // across runs and comparable with the gold manifest.
        let ordered = observations.sorted { a, b in
            let ay = 1.0 - a.boundingBox.maxY
            let by = 1.0 - b.boundingBox.maxY
            if abs(ay - by) > 0.005 { return ay < by }
            return a.boundingBox.minX < b.boundingBox.minX
        }

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
