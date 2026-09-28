import SwiftUI
import CizgiCore

// The pieces every Çıkmış screen draws a question with: the face's content,
// the option list, the figure crop and the booklet page. Shared so the session
// and the gap list show one question the same way.

enum ExamText {
    static let letters = ["A", "B", "C", "D", "E"]

    static func letter(_ index: Int) -> String {
        letters.indices.contains(index) ? letters[index] : "?"
    }

    static func session(_ session: Int) -> String {
        session == 1 ? "İlkbahar" : "Sonbahar"
    }

    static func test(_ test: ExamTest) -> String {
        switch test {
        case .temel: return "Temel"
        case .klinik: return "Klinik"
        case .temel2: return "Temel-2"
        }
    }

    static func testGroup(_ group: ExamTestGroup) -> String {
        group == .temel ? "Temel" : "Klinik"
    }

    static func sourceKind(_ kind: ExamSourceKind) -> String {
        switch kind {
        case .osym: return "ÖSYM"
        case .osymPartial: return "ÖSYM (kısmi)"
        case .tusdata: return "Tusdata"
        case .reconstruction: return "Yeniden dizim"
        }
    }

    static func answerSource(_ source: ExamAnswerSource) -> String {
        switch source {
        case .osym: return "ÖSYM"
        case .tusdata: return "Tusdata"
        case .reconstruction: return "yeniden dizim"
        }
    }

    static func issue(_ issue: ExamReportedIssue) -> String {
        switch issue {
        case .stem: return "Soru kökü"
        case .options: return "Şıklar"
        case .key: return "Cevap anahtarı"
        case .figure: return "Görsel"
        }
    }

    static func mode(_ mode: ExamRunMode) -> String {
        switch mode {
        case .practice: return "Pratik"
        case .mock: return "Deneme"
        case .wrongOnly: return "Yanlışlarım"
        case .gaps: return "Kitaba dönünce"
        }
    }

    /// "2019 · 1. dönem · Temel · 45 · Farmakoloji" — the face uppercases it.
    static func eyebrow(_ question: ExamQuestion) -> String {
        guard let id = ExamQuestionID(question.id) else { return question.id }
        var parts = ["\(id.year)", "\(id.session). dönem", test(id.test), "\(id.number)"]
        if let subject = question.osymSubject { parts.append(subject) }
        return parts.joined(separator: " · ")
    }

    /// "2019/1 Temel 45" — for list rows and captions.
    static func shortName(_ question: ExamQuestion) -> String {
        guard let id = ExamQuestionID(question.id) else { return question.id }
        return "\(id.year)/\(id.session) \(test(id.test)) \(id.number)"
    }

    static func net(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    static func percent(_ value: Double) -> String {
        "%\(Int((value * 100).rounded()))"
    }

    /// "1 sa 42 dk", "12 dk 5 sn", "48 sn".
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600, minutes = (total % 3_600) / 60, secs = total % 60
        if hours > 0 { return minutes > 0 ? "\(hours) sa \(minutes) dk" : "\(hours) sa" }
        if minutes > 0 { return secs > 0 && minutes < 10 ? "\(minutes) dk \(secs) sn" : "\(minutes) dk" }
        return "\(secs) sn"
    }

    /// "1:12:05" / "12:05" — the mock's countdown.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3_600, minutes = (total % 3_600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// "2019 İlkbahar · Temel".
    static func paperName(_ paper: ExamPaper) -> String {
        "\(paper.year) \(session(paper.session)) · \(test(paper.test))"
    }

    static func keySource(_ source: ExamKeySource) -> String {
        switch source {
        case .osym: return "ÖSYM"
        case .tusdata: return "Tusdata"
        case .reconstruction: return "yeniden dizim"
        case .missing: return "anahtarsız"
        }
    }
}

extension StudyFaceContent {
    /// How a past exam question fills the study face. Never a `Card`
    /// (docs/ADR-012): the face draws a value, and this is the question's.
    init(question: ExamQuestion, reportedIssue: ExamReportedIssue?) {
        var marks: [Mark] = []
        if question.isOld {
            marks.append(Mark(title: "eski", systemImage: "clock.arrow.circlepath"))
        }
        if let source = question.answerSource, source != .osym {
            marks.append(Mark(title: "anahtar: \(ExamText.answerSource(source))", systemImage: "key"))
        }
        if question.isReadOnly {
            marks.append(Mark(title: "anahtarsız", systemImage: "questionmark.circle"))
        }
        if reportedIssue != nil {
            marks.append(Mark(title: "bildirildi", systemImage: "flag.fill"))
        }
        self.init(
            type: .multipleChoice,
            eyebrow: ExamText.eyebrow(question),
            subject: CizgiSubject.matching(question.subject),
            question: question.stem,
            answer: nil,
            explanation: nil,
            marks: marks,
            // Still the serif — the question is one of the design's three
            // serif places — but sized for a vignette, not a flashcard.
            questionSize: 20
        )
    }
}

/// A–E. Before an answer every row is a button; after it the key is green, a
/// wrong pick red, and nothing can be changed.
///
/// In a mock (`allowsChange`) nothing is revealed and a mark is only a mark:
/// tapping another option moves it, tapping the marked one clears it — the
/// answer sheet, not a decision (plan §7.4 e).
struct ExamOptionList: View {
    let question: ExamQuestion
    /// `nil` while unanswered.
    let selected: Int?
    let isRevealed: Bool
    var allowsChange = false
    var onSelect: (Int) -> Void = { _ in }

    var body: some View {
        VStack(spacing: Cizgi.Space.sm) {
            ForEach(question.options.indices, id: \.self) { index in
                row(index)
            }
        }
    }

    private func row(_ index: Int) -> some View {
        let isKey = isRevealed && question.answer == index && question.isScoreable
        let isPicked = selected == index
        let isWrongPick = isRevealed && isPicked && !isKey && question.isScoreable
        let isMarked = !isRevealed && isPicked
        let tint: Color = isKey ? Cizgi.success : (isWrongPick ? Cizgi.danger : (isMarked ? Cizgi.accent : Cizgi.ink))
        let emphasised = isKey || isWrongPick || isMarked
        let text = question.options[index]

        return Button {
            guard !isRevealed else { return }
            onSelect(index)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Cizgi.Space.sm) {
                Text(ExamText.letter(index))
                    .font(.subheadline.weight(.bold).monospaced())
                    .foregroundStyle(emphasised ? tint : Cizgi.muted)
                Text(text == "[görsel]" ? "Görseldeki şık \(ExamText.letter(index))" : text)
                    .font(.body)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isKey {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(tint)
                } else if isWrongPick {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(tint)
                } else if isPicked {
                    Image(systemName: "circle.inset.filled").foregroundStyle(isMarked ? tint : Cizgi.muted)
                }
            }
            .padding(Cizgi.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Cizgi.surface)
            .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous)
                    .stroke(emphasised ? tint : Cizgi.hairline, lineWidth: emphasised ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        // Not `.disabled`: that also fades the row, and the green key and the
        // red pick are exactly what should read clearest once answered.
        .allowsHitTesting(!isRevealed)
        .accessibilityLabel(accessibility(index: index, text: text, isKey: isKey, isWrongPick: isWrongPick)
                            + (isMarked ? ", işaretli" : ""))
        .accessibilityHint(isMarked && allowsChange ? "Tekrar dokunmak işareti kaldırır." : "")
    }

    private func accessibility(index: Int, text: String, isKey: Bool, isWrongPick: Bool) -> String {
        let base = "\(ExamText.letter(index)) şıkkı, \(text)"
        if isKey { return base + ", doğru cevap" }
        if isWrongPick { return base + ", senin seçimin, yanlış" }
        return base
    }
}

/// What happened to an answered question, in one line under the rule.
struct ExamResultLine: View {
    let question: ExamQuestion
    let selectedOption: Int?

    var body: some View {
        let (text, tint) = content
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
    }

    private var content: (String, Color) {
        let key = ExamText.letter(question.answer ?? 0)
        let result = question.isScoreable
            ? ExamResult.of(selectedOption: selectedOption, answer: question.answer)
            : (selectedOption == nil ? .blank : .unscored)
        switch result {
        case .correct: return ("Doğru.", Cizgi.success)
        case .wrong: return ("Doğru cevap: \(key)", Cizgi.danger)
        case .blank:
            return (question.isScoreable ? "Boş bıraktın. Doğru cevap: \(key)" : "Boş bıraktın.", Cizgi.warning)
        case .unscored:
            return ("Bu sorunun anahtarı yok — kaynakta cevap basılı değil.", Cizgi.muted)
        }
    }
}

/// An image drawn from a packaged PDF, tappable to full screen like a page
/// photo (`SourcePageImage`'s behaviour, the same `SourceImageViewer`).
private struct ExamRenderedImage: View {
    let render: () async -> UIImage?
    let key: String
    var caption: String?
    var accessibilityLabel: String

    @State private var image: UIImage?
    @State private var failed = false
    @State private var isViewerPresented = false

    var body: some View {
        Group {
            if let image {
                Button {
                    isViewerPresented = true
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous)
                                .stroke(Cizgi.hairline, lineWidth: 1)
                        )
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(7)
                                .background(.black.opacity(0.45), in: Circle())
                                .padding(Cizgi.Space.sm)
                                .accessibilityHidden(true)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint("Tam ekran açar; iki parmakla yakınlaştırabilirsin.")
            } else if failed {
                Label("Kitapçık sayfası açılamadı", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Cizgi.muted)
            } else {
                RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous)
                    .fill(Cizgi.surfaceMuted)
                    .frame(height: 120)
                    .overlay { ProgressView() }
                    .accessibilityHidden(true)
            }
        }
        .task(id: key) {
            image = await render()
            failed = image == nil
        }
        .fullScreenCover(isPresented: $isViewerPresented) {
            if let image { SourceImageViewer(image: image, caption: caption) }
        }
    }
}

/// The question's own box from the booklet — shown under the stem when the
/// figure is part of the question (`required`) or pointed at (`reference`).
struct ExamFigureView: View {
    @EnvironmentObject private var examLibrary: ExamLibrary
    let question: ExamQuestion

    var body: some View {
        VStack(spacing: Cizgi.Space.sm) {
            ForEach(Array(question.provenance.enumerated()), id: \.offset) { _, region in
                if let url = examLibrary.pdfURL(for: region.pdf) {
                    ExamRenderedImage(
                        render: { await ExamPageRenderer.shared.crop(pdf: url, page: region.page, bbox: region.bbox) },
                        key: "\(region.pdf)#\(region.page)#\(region.bbox)",
                        caption: ExamText.shortName(question),
                        accessibilityLabel: "Sorunun kitapçıktaki görseli"
                    )
                }
            }
        }
    }
}

/// "Kaynağı göster": the booklet page, the question washed in its subject's
/// colour (plan D4). The ÖSYM booklet itself, never a retyped copy.
struct ExamSourceView: View {
    @EnvironmentObject private var examLibrary: ExamLibrary
    let question: ExamQuestion

    private var pages: [(pdf: String, page: Int, boxes: [[Double]])] {
        var result: [(pdf: String, page: Int, boxes: [[Double]])] = []
        for region in question.provenance {
            if let index = result.firstIndex(where: { $0.pdf == region.pdf && $0.page == region.page }) {
                result[index].boxes.append(region.bbox)
            } else {
                result.append((region.pdf, region.page, [region.bbox]))
            }
        }
        return result
    }

    var body: some View {
        let tint = UIColor(CizgiSubject.matching(question.subject)?.color ?? Cizgi.accent)
        VStack(alignment: .leading, spacing: Cizgi.Space.sm) {
            ForEach(Array(pages.enumerated()), id: \.offset) { _, entry in
                if let url = examLibrary.pdfURL(for: entry.pdf) {
                    ExamRenderedImage(
                        render: {
                            await ExamPageRenderer.shared.page(
                                pdf: url, page: entry.page, highlighting: entry.boxes, tint: tint
                            )
                        },
                        key: "\(entry.pdf)#\(entry.page)",
                        caption: "\(ExamText.shortName(question)) · kitapçık s. \(entry.page)",
                        accessibilityLabel: "Kitapçık sayfası \(entry.page)"
                    )
                } else {
                    Text("Kitapçık bu banka sürümünde yok.")
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                }
            }
            Text(sourceLine)
                .font(.caption)
                .foregroundStyle(Cizgi.muted)
        }
    }

    private var sourceLine: String {
        var parts = ["Metin: \(ExamText.sourceKind(textSourceKind))"]
        if let source = question.answerSource { parts.append("anahtar: \(ExamText.answerSource(source))") }
        if question.textQuality != .native { parts.append("metin görüntüden okundu") }
        return parts.joined(separator: " · ")
    }

    private var textSourceKind: ExamSourceKind {
        switch question.textSource {
        case .osym: return .osym
        case .tusdata: return .tusdata
        case .reconstruction: return .reconstruction
        }
    }
}
