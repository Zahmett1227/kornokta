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
public struct LocalLine: Codable, Sendable, Equatable {
    public let lineId: String
    public let text: String
    public let confidence: Double
    /// Normalized to the page, top-left origin — the same frame the backend uses.
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(
        lineId: String,
        text: String,
        confidence: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) {
        self.lineId = lineId
        self.text = text
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
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
            height: Double(line.box.height)
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
}

public struct RemotePage: Codable, Sendable, Equatable {
    public let imageWidth: Int
    public let imageHeight: Int
    public let elapsedMs: Int
    public let lines: [RemoteLine]
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
    public var timeout: TimeInterval

    public init(baseURL: URL, timeout: TimeInterval = 90) {
        self.baseURL = baseURL
        // Generous: a page can take Document AI several seconds, and the first
        // call of a session also pays for authentication.
        self.timeout = timeout
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
