import Foundation

/// Recognising a page you have already captured (ANA-PLAN §17, §21.1).
///
/// `CapturedPage.perceptualHash` has existed since Faz 1 and was never once
/// written to. Nothing in the app noticed a page it had already seen, so
/// photographing the same page twice — easy to do with a book open in front of
/// you, and the obvious thing to do after a blurry first shot — produced a
/// second full set of cards, and paid the provider a second time for them.
///
/// Difference hash rather than an average hash: it compares each pixel with its
/// right-hand neighbour, so it keys on *structure* (where the lines and margins
/// are) instead of overall brightness. Two shots of one page under different
/// lamps land close together; two different pages of the same book do not,
/// because their text blocks break in different places.
///
/// Deliberately Foundation-only. The caller supplies grayscale samples, which
/// keeps every decision here — the downsample, the bit layout, the distance,
/// the threshold — testable without an image decoder.
public struct PerceptualHash: Equatable, Hashable, Sendable, Codable {
    public let bits: UInt64

    public init(bits: UInt64) {
        self.bits = bits
    }

    /// Stored on `CapturedPage` as a string, so the model needs no new type.
    public var stringValue: String {
        String(format: "%016llx", bits)
    }

    public init?(stringValue: String) {
        guard stringValue.count == 16, let parsed = UInt64(stringValue, radix: 16) else { return nil }
        self.bits = parsed
    }
}

public enum PerceptualHasher {
    /// One extra column because each bit is a comparison between neighbours:
    /// nine samples across yield the eight bits of a row.
    public static let sampleWidth = 9
    public static let sampleHeight = 8

    /// How many of the 64 bits may differ before two pages are called the same.
    ///
    /// A first calibration, in the same spirit as the marker-detection
    /// thresholds — it has not been measured against a real set of re-shot
    /// pages, and it should not be trusted to *decide* anything. That is why the
    /// capture flow only ever asks, never refuses: the cost of a false positive
    /// is one extra tap, and the cost of a false negative is what we already
    /// have today.
    public static let duplicateThreshold = 6

    /// Averages the source down to `sampleWidth × sampleHeight`, then emits one
    /// bit per horizontal neighbour comparison.
    ///
    /// Returns `nil` for an image too small to sample, rather than padding it
    /// into a hash that would collide with everything.
    public static func hash(grayscale: [UInt8], width: Int, height: Int) -> PerceptualHash? {
        guard width >= sampleWidth, height >= sampleHeight, grayscale.count >= width * height else {
            return nil
        }

        var samples = [Int](repeating: 0, count: sampleWidth * sampleHeight)
        for row in 0..<sampleHeight {
            let yStart = row * height / sampleHeight
            let yEnd = max(yStart + 1, (row + 1) * height / sampleHeight)
            for column in 0..<sampleWidth {
                let xStart = column * width / sampleWidth
                let xEnd = max(xStart + 1, (column + 1) * width / sampleWidth)

                // Box average, not a single pixel: one sampled pixel would make
                // the hash turn on sensor noise and on exactly where the crop
                // happened to land.
                var total = 0
                var count = 0
                for y in yStart..<yEnd {
                    for x in xStart..<xEnd {
                        total += Int(grayscale[y * width + x])
                        count += 1
                    }
                }
                samples[row * sampleWidth + column] = count == 0 ? 0 : total / count
            }
        }

        var bits: UInt64 = 0
        var bitIndex = 0
        for row in 0..<sampleHeight {
            for column in 0..<(sampleWidth - 1) {
                let left = samples[row * sampleWidth + column]
                let right = samples[row * sampleWidth + column + 1]
                if left > right {
                    bits |= (1 << UInt64(bitIndex))
                }
                bitIndex += 1
            }
        }
        return PerceptualHash(bits: bits)
    }

    /// Hamming distance: how many of the 64 comparisons disagree.
    public static func distance(_ lhs: PerceptualHash, _ rhs: PerceptualHash) -> Int {
        (lhs.bits ^ rhs.bits).nonzeroBitCount
    }

    public static func isLikelyDuplicate(_ lhs: PerceptualHash, _ rhs: PerceptualHash) -> Bool {
        distance(lhs, rhs) <= duplicateThreshold
    }

    /// The closest already-captured page, when it is close enough to be worth
    /// mentioning.
    ///
    /// Returns the *nearest* match rather than the first: with several near
    /// misses the user should be shown the one they most likely meant, and the
    /// distance is what the caller uses to decide how firmly to put it.
    public static func nearestDuplicate<ID>(
        to hash: PerceptualHash,
        among candidates: [(id: ID, hash: PerceptualHash)]
    ) -> (id: ID, distance: Int)? {
        var best: (id: ID, distance: Int)?
        for candidate in candidates {
            guard isLikelyDuplicate(hash, candidate.hash) else { continue }
            let distance = distance(hash, candidate.hash)
            if best == nil || distance < best!.distance {
                best = (candidate.id, distance)
            }
        }
        return best
    }
}
