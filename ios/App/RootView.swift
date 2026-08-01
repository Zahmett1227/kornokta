import SwiftUI
import SwiftData
import CizgiCore

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        TabView {
            CaptureView()
                .tabItem { Label("Yakala", systemImage: "camera") }

            ReviewView()
                .tabItem { Label("Tekrar", systemImage: "rectangle.stack") }

            LibraryView()
                .tabItem { Label("Bilgilerim", systemImage: "books.vertical") }

            SettingsView()
                .tabItem { Label("Ayarlar", systemImage: "gearshape") }
        }
        .task {
            // Pick up anything left unfinished by a previous launch (§24.1:
            // pending work must survive the app closing).
            await environment.queue.processPending()
        }
    }
}

/// Semantic colours from §29. Status is never conveyed by colour alone — every
/// use pairs it with a label or an icon.
extension ProcessingState {
    var tint: Color {
        switch self {
        case .ready: return .green
        case .confirmationRequired: return .orange
        case .permanentFailure: return .red
        case .cancelled: return .gray
        case .temporaryFailure: return .orange
        default: return .blue
        }
    }

    var label: String {
        switch self {
        case .captured: return "Bekliyor"
        case .localPreprocessing: return "Hazırlanıyor"
        case .localOCR: return "Yerel OCR"
        case .markerDetection: return "İşaret aranıyor"
        case .cloudOCR: return "Bulut OCR"
        case .transcriptionReconciliation: return "Doğrulanıyor"
        case .confirmationRequired: return "Onay gerekli"
        case .cardGeneration: return "Kart oluşturuluyor"
        case .qualityValidation: return "Kalite kontrolü"
        case .ready: return "Hazır"
        case .temporaryFailure: return "Geçici hata"
        case .permanentFailure: return "Hata"
        case .cancelled: return "İptal edildi"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .confirmationRequired: return "hand.raised.fill"
        case .permanentFailure: return "xmark.octagon.fill"
        case .temporaryFailure: return "arrow.clockwise.circle.fill"
        case .cancelled: return "slash.circle"
        default: return "clock.fill"
        }
    }
}
