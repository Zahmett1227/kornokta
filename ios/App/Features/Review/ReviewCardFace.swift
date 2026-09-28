import SwiftUI
import CizgiCore

/// The card as Tekrar and Egzersiz both show it — "kâğıt ve mürekkep".
///
/// ### Why the card is no longer a box
///
/// It used to be a `CardSurface`: a rounded rectangle in `surface`, a hairline
/// border, a 3px subject stripe across the top, floating on `paper`. Two things
/// were wrong with it. The surface sits 5% off the page background, so the box
/// barely read as an object at all — it cost a border, a corner radius and a
/// stripe to draw something the eye could not quite see. And a box has to be
/// *somewhere*: a short card left it stranded in the middle of an empty screen,
/// which is what made the old layout feel hollow.
///
/// So the box is gone and the page is the card. What is left is the subject's
/// colour as a rule down the left margin — a bound book's edge rubric, standing
/// beside the thing being read rather than capping it — and ink on paper.
///
/// ### Why it is shared
///
/// The two screens had a near-identical copy of this each, differing only in
/// which chips they showed. They are the same object seen twice; keeping two
/// copies is how the FES chip ended up on one and the topic chip on neither.
/// The parts that genuinely differ are the two slots: `options` (each screen
/// owns its own selection state) and `footer` (the source disclosure, which
/// needs each screen's image store).
///
/// ### Why it draws a value, not a `Card`
///
/// A past exam question needs this same page and is not a card
/// (`StudyFaceContent` explains the rest). The card-shaped initializer below
/// keeps Tekrar's and Egzersiz's call sites exactly as they were.
struct ReviewCardFace<Options: View, Footer: View>: View {
    let content: StudyFaceContent
    let isAnswerVisible: Bool
    @ViewBuilder var options: () -> Options
    @ViewBuilder var footer: () -> Footer

    /// The rule falls back to the accent when the item has no recognised
    /// subject, so the margin is never blank — an absent rule would read as a
    /// design slip rather than as missing data.
    private var rule: Color { content.subject?.color ?? Cizgi.accent }

    var body: some View {
        HStack(alignment: .top, spacing: Cizgi.Space.lg) {
            // Flexible in height, so it runs the full length of the text
            // beside it however long the answer turns out to be.
            Capsule()
                .fill(rule)
                .frame(width: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Cizgi.Space.lg) {
                HStack(spacing: Cizgi.Space.sm) {
                    // The mark stays decorative (it hides itself from
                    // VoiceOver); the type name it draws is spoken by the line
                    // beside it, which also restores the uppercased text to
                    // its real casing.
                    CardTypeMark(type: content.type, size: 17, tint: rule)
                    // `uppercased()` alone gives "ENDOKRIN SISTEM" — right in
                    // English, wrong here (docs/ADR-001).
                    Text(TurkishText.uppercased(content.eyebrow))
                        .font(.caption2.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(Cizgi.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityLabel("\(content.type.displayName), \(content.eyebrow)")
                }

                // Serifin üç yerinden biri: kart sorusu. Kutunun dolgusu
                // kalktığı için satır genişledi ve punto bir kademe büyüdü.
                Text(content.question)
                    .font(Cizgi.serif(content.questionSize, relativeTo: .title2))
                    .lineSpacing(3)
                    .foregroundStyle(Cizgi.ink)
                    .fixedSize(horizontal: false, vertical: true)

                options()

                if isAnswerVisible {
                    // Tasarımın soru/cevap kesmesi: düz çizgi değil baklava
                    // ayırıcı — sayfanın iki yarısını ayıran şey.
                    CizgiRule()

                    // On a five-option card the answer is already marked in the
                    // list above; repeating it as a line of text would push the
                    // reasons off screen — `StudyFaceContent` leaves it `nil`.
                    if let answer = content.answer {
                        Text(answer)
                            .font(.body)
                            .foregroundStyle(Cizgi.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let explanation = content.explanation, !explanation.isEmpty {
                        // § işareti açıklamayı cevaptan ayırır: cevap sayfanın
                        // sorduğu şey, açıklama kenar notu.
                        HStack(alignment: .firstTextBaseline, spacing: Cizgi.Space.sm) {
                            CizgiSectionMark()
                            Text(explanation)
                                .font(.subheadline)
                                .foregroundStyle(Cizgi.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    footer()
                }

                if !content.marks.isEmpty {
                    // Under the text rather than over it. These are notes
                    // *about* the card, and at the top — where they used to
                    // sit, as a row of chips above the question — they were
                    // the first thing read on a screen whose whole job is to
                    // put the question first.
                    HStack(spacing: Cizgi.Space.sm) {
                        ForEach(content.marks, id: \.self) { mark in
                            TagChip(mark.title, systemImage: mark.systemImage)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: isAnswerVisible)
    }
}

extension ReviewCardFace {
    /// Tekrar and Egzersiz's way in: the face as it was before it took a
    /// value. `showsFesMark` — Egzersiz marks a FES card once the answer is
    /// out; Tekrar does not.
    init(
        card: Card,
        isAnswerVisible: Bool,
        showsFesMark: Bool = false,
        @ViewBuilder options: @escaping () -> Options,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.init(
            content: StudyFaceContent(card: card, isAnswerVisible: isAnswerVisible, showsFesMark: showsFesMark),
            isAnswerVisible: isAnswerVisible,
            options: options,
            footer: footer
        )
    }
}
