import Foundation

/// The phone's side of the backend contract (ANA-PLAN §7.2, §7.3).
///
/// The API key lives on the server and never on the device, so every cloud
/// call goes through here. The device authenticates with a long random token
/// held in the Keychain — that is the whole security model for a single-user
/// app, and it is enough to keep the Google key out of reach of anyone who
/// finds the URL.

/// One line of the phone's own reading, sent so the backend can reconcile.
///
/// Geometry is included because the backend pairs lines by **where they sit**,
/// not by id: the two engines number their own lines independently and do not
/// find the same number of them, so `line_07` is a different physical line in
/// each. Pairing by id would compare unrelated lines and raise disagreements
/// that do not exist.
public struct LocalToken: Codable, Sendable, Equatable, Identifiable {
    public let tokenId: String
    public let text: String
    public let confidence: Double
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public var id: String { tokenId }

    public init(
        tokenId: String,
        text: String,
        confidence: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) {
        self.tokenId = tokenId
        self.text = text
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ token: RecognizedToken) {
        self.init(
            tokenId: token.id,
            text: token.text,
            confidence: token.confidence,
            x: Double(token.box.minX),
            y: Double(token.box.minY),
            width: Double(token.box.width),
            height: Double(token.box.height)
        )
    }

    public init(_ token: LocalToken) {
        self = token
    }
}

public struct LocalLine: Codable, Sendable, Equatable {
    public let lineId: String
    public let text: String
    public let confidence: Double
    /// Normalized to the page, top-left origin — the same frame the backend uses.
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let tokens: [LocalToken]

    public init(
        lineId: String,
        text: String,
        confidence: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        tokens: [LocalToken] = []
    ) {
        self.lineId = lineId
        self.text = text
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.tokens = tokens
    }

    /// Builds the wire form from a local recognition result.
    public init(_ line: RecognizedLine) {
        self.init(
            lineId: line.id,
            text: line.text,
            confidence: line.confidence,
            x: Double(line.box.minX),
            y: Double(line.box.minY),
            width: Double(line.box.width),
            height: Double(line.box.height),
            tokens: line.tokens.map(LocalToken.init)
        )
    }
}

/// Decoded from the backend. Field names match the server's JSON exactly.
public struct RemoteLine: Codable, Sendable, Equatable {
    public let lineId: String
    public let text: String
    public let confidence: Double
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let tokenIds: [String]

    public init(
        lineId: String,
        text: String,
        confidence: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        tokenIds: [String] = []
    ) {
        self.lineId = lineId
        self.text = text
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.tokenIds = tokenIds
    }
}

public struct RemoteColor: Codable, Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct RemoteToken: Codable, Sendable, Equatable, Identifiable {
    public let tokenId: String
    public let text: String
    public let confidence: Double
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let isHandwritten: Bool
    public let isUnderlined: Bool
    public let backgroundColor: RemoteColor?

    public var id: String { tokenId }

    public init(
        tokenId: String,
        text: String,
        confidence: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        isHandwritten: Bool = false,
        isUnderlined: Bool = false,
        backgroundColor: RemoteColor? = nil
    ) {
        self.tokenId = tokenId
        self.text = text
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isHandwritten = isHandwritten
        self.isUnderlined = isUnderlined
        self.backgroundColor = backgroundColor
    }

    public var boundingBox: NormalizedRect {
        NormalizedRect(x: x, y: y, width: width, height: height)
    }
}

public struct RemoteLayoutRegion: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: AnnotationLayoutKind
    public let text: String
    public let confidence: Double
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(
        id: String,
        kind: AnnotationLayoutKind,
        text: String,
        confidence: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var boundingBox: NormalizedRect {
        NormalizedRect(x: x, y: y, width: width, height: height)
    }
}

public struct RemotePage: Codable, Sendable, Equatable {
    public let imageWidth: Int
    public let imageHeight: Int
    public let elapsedMs: Int
    public let lines: [RemoteLine]
    public let tokens: [RemoteToken]
    public let paragraphs: [RemoteLayoutRegion]
    public let blocks: [RemoteLayoutRegion]
    public let tables: [RemoteLayoutRegion]

    public init(
        imageWidth: Int,
        imageHeight: Int,
        elapsedMs: Int,
        lines: [RemoteLine],
        tokens: [RemoteToken] = [],
        paragraphs: [RemoteLayoutRegion] = [],
        blocks: [RemoteLayoutRegion] = [],
        tables: [RemoteLayoutRegion] = []
    ) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.elapsedMs = elapsedMs
        self.lines = lines
        self.tokens = tokens
        self.paragraphs = paragraphs
        self.blocks = blocks
        self.tables = tables
    }
}

/// What the backend decided about the two readings (§19.2, §19.3).
public enum RemoteDecision: String, Codable, Sendable {
    case autoAccept = "auto_accept"
    case quickConfirm = "quick_confirm"
    case reject
}

public struct RemoteLineReconciliation: Codable, Sendable, Equatable {
    public let lineId: String
    public let primaryText: String
    public let secondaryText: String?
    public let agrees: Bool
    public let criticalTokenFlags: [String]
}

public struct RemoteReconciliation: Codable, Sendable, Equatable {
    public let decision: RemoteDecision
    public let reason: String
    public let text: String
    public let lines: [RemoteLineReconciliation]
    public let criticalLineIds: [String]
}

public struct RemoteRecognition: Codable, Sendable, Equatable {
    public let jobId: String
    public let page: RemotePage
    /// Absent when the request carried no local reading to compare against.
    public let reconciliation: RemoteReconciliation?
    /// Echoes the backend's `DOCUMENTAI_COMPUTE_STYLE_INFO` for this call —
    /// without it, `isUnderlined: false`/no `backgroundColor` on every token
    /// looks identical whether the style add-on ran and found nothing, or
    /// was never requested at all, and only the server actually knows which.
    public let styleInfoRequested: Bool

    public init(jobId: String, page: RemotePage, reconciliation: RemoteReconciliation?, styleInfoRequested: Bool = false) {
        self.jobId = jobId
        self.page = page
        self.reconciliation = reconciliation
        self.styleInfoRequested = styleInfoRequested
    }

    /// A persisted `OCRSnapshot` from before this field existed has no
    /// `styleInfoRequested` key at all. Defaulting to `false` there is the
    /// safe reading: those snapshots predate the style feature entirely, so
    /// they certainly never requested it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try container.decode(String.self, forKey: .jobId)
        page = try container.decode(RemotePage.self, forKey: .page)
        reconciliation = try container.decodeIfPresent(RemoteReconciliation.self, forKey: .reconciliation)
        styleInfoRequested = try container.decodeIfPresent(Bool.self, forKey: .styleInfoRequested) ?? false
    }
}

public enum BackendError: Error, Sendable, Equatable {
    /// No URL or no device token configured yet.
    case notConfigured(String)
    case unauthorized
    /// Worth another attempt later (§17).
    case transient(String)
    /// Retrying will reproduce it.
    case permanent(String)

    public var isTransient: Bool {
        if case .transient = self { return true }
        return false
    }
}

/// The backend, behind a protocol so the pipeline can be driven by a stub.
public protocol BackendCalling: Sendable {
    func recognize(
        jobId: String,
        imageData: Data,
        mimeType: String,
        localLines: [LocalLine]
    ) async throws -> RemoteRecognition
}

public struct BackendConfiguration: Sendable, Equatable {
    public var baseURL: URL
    /// Ceiling for one HTTP request.
    public var timeout: TimeInterval
    /// How long `BackendCardProvider` keeps collecting one job's answer.
    public var jobDeadline: TimeInterval

    public init(baseURL: URL, timeout: TimeInterval = 300, jobDeadline: TimeInterval = 420) {
        self.baseURL = baseURL
        // An upper bound, not a target. Under ADR-006 every card call is either
        // a page upload or a small poll, both of which answer in seconds; this
        // stays generous so the retained synchronous `/api/cards-vision` and OCR
        // paths (which really can run for minutes) are not cut off by it.
        self.timeout = timeout
        // Seven minutes: comfortably past the backend's own 300 s ceiling, so a
        // job that is going to finish normally does finish inside one call.
        // Passing it is not a lost page — the job keeps running on the server
        // and the next attempt collects it (docs/ADR-006 §4).
        self.jobDeadline = jobDeadline
    }
}

public struct BackendClient: BackendCalling {
    private let configuration: BackendConfiguration
    private let tokenProvider: @Sendable () -> String?
    private let session: URLSession

    /// The token is fetched per call rather than captured, so changing it in
    /// Settings takes effect immediately instead of on the next launch.
    public init(
        configuration: BackendConfiguration,
        tokenProvider: @escaping @Sendable () -> String?,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.session = session
    }

    public func recognize(
        jobId: String,
        imageData: Data,
        mimeType: String,
        localLines: [LocalLine]
    ) async throws -> RemoteRecognition {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw BackendError.notConfigured("Cihaz anahtarı ayarlanmamış.")
        }

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("api/ocr"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = RequestBody(
            jobId: jobId,
            mimeType: mimeType,
            imageBase64: imageData.base64EncodedString(),
            localLines: localLines.isEmpty ? nil : localLines
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // No connection, DNS failure, timeout: all worth retrying, and
            // none of them mean the capture is lost (§21.2).
            throw BackendError.transient(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BackendError.transient("Beklenmeyen yanıt türü.")
        }

        if http.statusCode == 401 {
            throw BackendError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let failure = try? JSONDecoder().decode(FailureBody.self, from: data)
            let message = failure?.error ?? "Sunucu hatası (\(http.statusCode))."
            // The server states whether it is worth retrying; trusting its
            // answer keeps the retry rule in one place (§17).
            let retryable = failure?.retryable ?? (http.statusCode >= 500)
            throw retryable ? BackendError.transient(message) : BackendError.permanent(message)
        }

        do {
            return try JSONDecoder().decode(RemoteRecognition.self, from: data)
        } catch {
            // A reply we cannot parse will not parse on a second attempt
            // either — it is a contract problem, not a blip (§17).
            throw BackendError.permanent("Sunucu yanıtı çözümlenemedi: \(error)")
        }
    }

    private struct RequestBody: Encodable {
        let jobId: String
        let mimeType: String
        let imageBase64: String
        let localLines: [LocalLine]?
    }

    private struct FailureBody: Decodable {
        let error: String
        let retryable: Bool
    }
}
