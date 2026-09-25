import SwiftUI
import SwiftData
import CizgiCore

/// Where each `ExamRoute` goes — one table, registered on every stack that
/// can push a Çıkmış screen (Egzersiz and Bilgilerim).
struct ExamRouteDestination: View {
    let route: AppNavigator.ExamRoute

    var body: some View {
        switch route {
        case .home: ExamHomeView()
        case .session(let id): ExamSessionView(runId: id)
        case .mock(let id): ExamMockView(runId: id)
        case .mockPapers: ExamPaperPickerView()
        case .result(let id): ExamResultScreen(runId: id)
        case .review(let id): ExamReviewView(runId: id)
        case .gaps: ExamGapsView()
        case .question(let id): ExamQuestionDetailView(questionId: id)
        case .bankSettings: ExamBankSettingsView()
        }
    }
}

extension View {
    func examRouteDestinations() -> some View {
        navigationDestination(for: AppNavigator.ExamRoute.self) { ExamRouteDestination(route: $0) }
    }
}

/// Egzersiz's fourth quick start (plan §7.4 a): the big serif number is the
/// scoreable questions never answered; the line under it, the misses and the
/// open gaps. Its own view with its own query, so the exercise screen does
/// not redraw on every exam answer — nor this one on every card change.
struct ExamEntryRow: View {
    @EnvironmentObject private var examLibrary: ExamLibrary
    @EnvironmentObject private var navigator: AppNavigator
    @Query private var states: [ExamQuestionState]

    var body: some View {
        let summary = self.summary
        NumeralActionRow(numeral: summary.numeral, title: "Çıkmış", subtitle: summary.subtitle) {
            navigator.exercisePath.append(AppNavigator.ExamRoute.home)
        }
    }

    private var summary: (numeral: String, subtitle: String) {
        guard let bank = examLibrary.bank else {
            switch examLibrary.phase {
            case .loading: return ("…", "Soru bankası okunuyor")
            case .failed: return ("!", "Soru bankası okunamadı")
            default: return ("—", "Soru bankası yok — Ayarlar'dan içe aktar")
            }
        }
        var attempted = 0, wrong = 0, gaps = 0
        for state in states {
            let scoreable = bank.scoreableIds.contains(state.questionId)
            if scoreable, state.attemptCount > 0 { attempted += 1 }
            if scoreable, state.progress.isWrong { wrong += 1 }
            if state.gap.status == .open, bank.questionsById[state.questionId] != nil { gaps += 1 }
        }
        let unsolved = bank.scoreableIds.count - attempted
        let subtitle = wrong == 0 && gaps == 0
            ? "Gerçek TUS soruları, kitapsız"
            : "yanlışlarım \(wrong) · açık \(gaps)"
        return (unsolved.formatted(), subtitle)
    }
}
