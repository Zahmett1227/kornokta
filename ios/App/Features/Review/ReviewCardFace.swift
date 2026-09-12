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
struct ReviewCardFace<Options: View, Footer: View>: View {
    let card: Card
    let isAnswerVisible: Bool
    /// Egzersiz marks a FES card once the answer is out; Tekrar does not.
    /// Never before the reveal — seeing "this one is hard" before trying to
    /// recall it contaminates the very measurement FES is built from.
    var showsFesMark = false
    @ViewBuilder var options: () -> Options
    @ViewBuilder var footer: () -> Footer

    private var subject: CizgiSubject? {
        CizgiSubject.matching(card.knowledgeUnit?.subject)
    }

    /// The rule falls back to the accent when the card has no recognised
    /// subject, so the margin is never blank — an absent rule would read as a
    /// design slip rather than as missing data.
    private var rule: Color { subject?.color ?? Cizgi.accent }

    /// Where the card sits, in the order a reader wants it: subject, then
    /// topic. The question's *type* is not repeated here — `CardTypeMark`
    /// draws its shape, which is what that mark exists for. If the card has
    /// neither subject nor topic the type name stands in, so the line is never
    /// empty.
    private var eyebrow: String {
        let parts = [card.knowledgeUnit?.subject, card.knowledgeUnit?.topic]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? card.type.displayName : parts.joined(separator: " · ")
    }

    private var marks: [(String, String)] {
        var marks: [(String, String)] = []
        // Flagged, not blocked (§13.3 rule 6): the card is reviewed like any
        // other, but the user is told it was never fully vouched for before
        // they trust the answer. The old `DogEar` that said this a second time
        // is gone with the box it was folded into — the chip carries both an
        // icon and the words, so the meaning never rested on colour anyway.
        if card.lowConfidence {
            marks.append(("Gözden geçir", "exclamationmark.triangle.fill"))
        }
        if showsFesMark, isAnswerVisible, FesScore.isFes(score: card.fesScore) {
            marks.append(("FES", "flame.fill"))
        }
        return marks
    }

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
                    CardTypeMark(type: card.type, size: 17, tint: rule)
                    // `uppercased()` alone gives "ENDOKRIN SISTEM" — right in
                    // English, wrong here (docs/ADR-001).
                    Text(TurkishText.uppercased(eyebrow))
                        .font(.caption2.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(Cizgi.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityLabel("\(card.type.displayName), \(eyebrow)")
                }

                // Serifin üç yerinden biri: kart sorusu. Kutunun dolgusu
                // kalktığı için satır genişledi ve punto bir kademe büyüdü.
                Text(card.front)
                    .font(Cizgi.serif(27, relativeTo: .title2))
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
                    // reasons off screen.
                    if card.options == nil {
                        Text(card.back)
                            .font(.body)
                            .foregroundStyle(Cizgi.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let explanation = card.explanation, !explanation.isEmpty {
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

                if !marks.isEmpty {
                    // Under the text rather than over it. These are notes
                    // *about* the card, and at the top — where they used to
                    // sit, as a row of chips above the question — they were
                    // the first thing read on a screen whose whole job is to
                    // put the question first.
                    HStack(spacing: Cizgi.Space.sm) {
                        ForEach(marks, id: \.0) { title, icon in
                            TagChip(title, systemImage: icon)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: isAnswerVisible)
    }
}
