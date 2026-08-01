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

    @Published var settings: AppSettings

    init(container: ModelContainer) throws {
        let store = try ImageStore(root: try ImageStore.defaultRoot())
        self.imageStore = store
        self.scheduler = PlaceholderScheduler()
        self.settings = AppSettings.load()

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
                generator: MockCardProvider()
            )
        )
    }
}

/// User-facing preferences (§6.7). Stored in UserDefaults; nothing here is
/// sensitive.
struct AppSettings: Codable, Equatable {
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
