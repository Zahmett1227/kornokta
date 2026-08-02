import Foundation
import SwiftData
import SwiftUI
import CizgiCore

/// Shared services for the app.
///
/// Faz 1 wires the local pieces only: Vision OCR and the offline mock
/// generator. The cloud OCR and the real card model arrive in Faz 2/3 behind
/// the same protocols (ANA-PLAN §25), so nothing here changes shape.
@MainActor
final class AppEnvironment: ObservableObject {
    let imageStore: ImageStore
    let scheduler: any ReviewScheduling
    let queue: ProcessingQueue
    let tokenStore: any DeviceTokenStoring

    @Published var settings: AppSettings

    init(container: ModelContainer) throws {
        let store = try ImageStore(root: try ImageStore.defaultRoot())
        self.imageStore = store
        self.scheduler = PlaceholderScheduler()
        self.settings = AppSettings.load()

        #if canImport(Security)
        let tokens: any DeviceTokenStoring = KeychainDeviceTokenStore()
        #else
        let tokens: any DeviceTokenStoring = InMemoryDeviceTokenStore()
        #endif
        self.tokenStore = tokens

        #if canImport(Vision)
        let recognizer: any TextRecognizing = VisionTextRecognizer()
        #else
        let recognizer: any TextRecognizing = UnavailableRecognizer()
        #endif

        self.queue = ProcessingQueue(
            container: container,
            imageStore: store,
            pipeline: CapturePipeline(
                recognizer: recognizer,
                selector: ManualSelectionOnly(),
                generator: MockCardProvider(),
                backend: Self.makeBackend(settings: self.settings, tokens: tokens)
            )
        )
    }

    /// Builds the cloud OCR client, or nil when the user has not set it up.
    ///
    /// Nil is a normal state, not an error: capture, local OCR and review all
    /// work without it (§24.1, §24.5). What does not work is Turkish text,
    /// which is why Settings says so out loud rather than letting the app look
    /// broken.
    static func makeBackend(
        settings: AppSettings,
        tokens: any DeviceTokenStoring
    ) -> (any BackendCalling)? {
        let trimmed = settings.backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            let url = URL(string: trimmed),
            url.scheme != nil,
            tokens.read()?.isEmpty == false
        else { return nil }

        return BackendClient(
            configuration: BackendConfiguration(baseURL: url),
            // Read per call rather than captured, so changing the token in
            // Settings takes effect on the next page instead of next launch.
            tokenProvider: { tokens.read() }
        )
    }

    /// Re-reads the settings and rebuilds the cloud client. Called when the
    /// user edits the backend URL or the token.
    func backendChanged() {
        queue.setBackend(Self.makeBackend(settings: settings, tokens: tokenStore))
    }

    var isBackendConfigured: Bool {
        Self.makeBackend(settings: settings, tokens: tokenStore) != nil
    }
}

/// User-facing preferences (§6.7). Stored in UserDefaults; nothing here is
/// sensitive.
struct AppSettings: Codable, Equatable {
    /// Base URL of the backend proxy, e.g. `https://cizgi.example.com`.
    /// Not a secret — the device token is what authorizes, and that lives in
    /// the Keychain (§7.3).
    var backendURL: String = ""
    var defaultSubject: String = ""
    var maxCardsPerPassage: Int = 2
    var sourceFaithfulOnly: Bool = true
    var notificationHour: Int = 20
    var keepOriginalPage: Bool = true

    static let storageKey = "cizgi.settings.v1"

    static func load() -> AppSettings {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

/// Used on platforms without Vision so the app still builds and the failure is
/// explicit rather than a silent empty result.
struct UnavailableRecognizer: TextRecognizing {
    func recognize(imageAt url: URL) async throws -> RecognizedPage {
        throw TextRecognitionError.recognitionFailed("Bu platformda Vision yok")
    }
}
