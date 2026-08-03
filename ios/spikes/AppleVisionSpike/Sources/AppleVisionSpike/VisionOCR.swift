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

    /// Buckets used to scan for column gutters in `columnBoundaries(for:)`.
    static let columnBuckets = 100
    /// A gutter narrower than this fraction of the page width is ordinary word
    /// spacing, not a column break.
    static let minGutterWidth = 0.02
    /// A gutter this close to either edge is a margin, not a break between
    /// columns of text.
    static let columnEdgeMargin = 0.08
    /// Every column a detected gutter implies must end up with at least this
    /// many lines, or the "gutter" was probably one short/indented line, not
    /// a layout.
    static let minLinesPerColumn = 2

    /// Vision returns observations in no guaranteed reading order, so they are
    /// sorted top-to-bottom then left-to-right for stable `lineId` numbering —
    /// except that a page split into columns (e.g. a Nekroz/Apoptoz
    /// comparison list) reads column by column, not row by row: reading
    /// row-by-row across columns interleaves two unrelated sentences into one
    /// garbled line.
    ///
    /// The vertical position is **quantized into bands** rather than compared
    /// with a tolerance. `abs(ay - by) > epsilon` is not a strict weak
    /// ordering: `a ≈ b` and `b ≈ c` can hold while `a < c` does too, and
    /// `sorted(by:)` given such a predicate returns an arbitrary permutation.
    /// On a dense page that scrambles the whole transcript. Rounding to a band
    /// is transitive, so the sort is well-defined.
    ///
    /// Kept identical to `CizgiCore.ReadingOrder` (same constants, same
    /// algorithm) — the Faz 0 measurement is only meaningful if a future
    /// re-measurement orders lines the same way the app does.
    static func inReadingOrder(
        _ observations: [VNRecognizedTextObservation]
    ) -> [VNRecognizedTextObservation] {
        func band(_ observation: VNRecognizedTextObservation) -> Int {
            // Flip to a top-left origin first, so band 0 is the top of the page.
            Int(((1.0 - observation.boundingBox.maxY) / bandHeight).rounded())
        }
        func withinColumn(_ a: VNRecognizedTextObservation, _ b: VNRecognizedTextObservation) -> Bool {
            let bandA = band(a), bandB = band(b)
            if bandA != bandB { return bandA < bandB }
            return a.boundingBox.minX < b.boundingBox.minX
        }

        let boundaries = columnBoundaries(for: observations)
        guard !boundaries.isEmpty else {
            return observations.sorted(by: withinColumn)
        }

        func columnIndex(_ observation: VNRecognizedTextObservation) -> Int {
            boundaries.filter { $0 < observation.boundingBox.midX }.count
        }

        var byColumn: [Int: [VNRecognizedTextObservation]] = [:]
        for observation in observations {
            byColumn[columnIndex(observation), default: []].append(observation)
        }
        return (0...boundaries.count).flatMap { column in
            (byColumn[column] ?? []).sorted(by: withinColumn)
        }
    }

    /// Finds x-positions of vertical whitespace gutters wide and central
    /// enough to be column breaks rather than ordinary margins. A handful of
    /// full-width outliers (a header, a page number) are tolerated —
    /// `crossingTolerance` — rather than blocking detection outright.
    static func columnBoundaries(for observations: [VNRecognizedTextObservation]) -> [Double] {
        guard observations.count >= 2 * minLinesPerColumn else { return [] }

        var coverage = [Int](repeating: 0, count: columnBuckets)
        for observation in observations {
            let box = observation.boundingBox
            let start = max(0, Int((box.minX * Double(columnBuckets)).rounded(.down)))
            let end = min(columnBuckets, Int((box.maxX * Double(columnBuckets)).rounded(.up)))
            guard start < end else { continue }
            for bucket in start..<end { coverage[bucket] += 1 }
        }

        let crossingTolerance = max(1, observations.count / 20)
        var boundaries: [Double] = []
        var index = 0
        while index < columnBuckets {
            guard coverage[index] <= crossingTolerance else { index += 1; continue }
            let start = index
            while index < columnBuckets, coverage[index] <= crossingTolerance { index += 1 }
            let width = Double(index - start) / Double(columnBuckets)
            let center = (Double(start) + Double(index)) / 2 / Double(columnBuckets)
            if width >= minGutterWidth, center >= columnEdgeMargin, center <= 1 - columnEdgeMargin {
                boundaries.append(center)
            }
        }

        guard !boundaries.isEmpty else { return [] }

        var perColumn = [Int](repeating: 0, count: boundaries.count + 1)
        for observation in observations {
            let center = observation.boundingBox.midX
            perColumn[boundaries.filter { $0 < center }.count] += 1
        }
        guard perColumn.allSatisfy({ $0 >= minLinesPerColumn }) else { return [] }

        return boundaries
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
