import SwiftUI
import CizgiCore

/// "Kuyruk" — the queued half of an imported concept pack, and the button that
/// lets some of it into the deck.
///
/// This is the whole user-facing half of the batch-release decision
/// (2026-09-10). There is no quota, no weekday schedule and no automatic drip,
/// because a number set in advance cannot know about the day it lands on: a
/// night shift makes 40 cards a punishment and a free Sunday makes it a waste.
/// Pressing a button costs one tap on the days he wants cards and nothing at
/// all on the days he does not.
///
/// Lives beside `LibraryView` rather than inside it because that file is
/// already 600 lines and this has its own shape; it takes a closure rather than
/// a `ModelContext` so the write stays in one place (`LibraryView.release`).
struct ConceptQueueSection: View {
    /// The queued cards *as the screen is filtered* — so the count shown and
    /// the cards released are the same set the owner is looking at.
    let queued: [Card]
    /// Asks for at least this many cards. Whole concepts are released, so the
    /// batch is usually a little larger; the footer says so rather than
    /// pretending the number is exact.
    let release: (Int) -> Void

    /// Small, medium, large. Three sizes rather than a stepper: the decision
    /// being made is "light day / normal day / heavy day", not a precise count,
    /// and a stepper invites fiddling with a number that the whole-concept rule
    /// will round anyway.
    private let batches = [10, 25, 50]

    /// How many distinct concepts are waiting. The more honest unit of the two:
    /// cards are what gets scheduled, concepts are what gets learned.
    private var conceptCount: Int {
        Set(queued.compactMap { $0.knowledgeUnit?.id }).count
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                Text("\(queued.count) kart · \(conceptCount) kavram bekliyor")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Cizgi.ink)

                HStack(spacing: Cizgi.Space.sm) {
                    ForEach(batches, id: \.self) { size in
                        Button {
                            release(size)
                        } label: {
                            Text("+\(size)")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Cizgi.Space.sm)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Cizgi.accent)
                        // A batch bigger than the queue would read as a promise
                        // the queue cannot keep; the smaller buttons still work
                        // and the last one empties it.
                        .disabled(queued.isEmpty)
                    }
                }

                Text("Bütün kavramlar birlikte açılır, o yüzden gelen sayı biraz fazla olabilir. Açılan kartlar bugün tekrara düşer; kuyrukta bekleyenler hiçbir yerde görünmez.")
                    .font(.caption)
                    .foregroundStyle(Cizgi.muted)
            }
            .listRowInsets(EdgeInsets(top: Cizgi.Space.md, leading: Cizgi.Space.lg,
                                      bottom: Cizgi.Space.md, trailing: Cizgi.Space.lg))
            .listRowBackground(Cizgi.surface)
            .listRowSeparator(.hidden)
        } header: {
            Text("Kuyruk")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Cizgi.muted)
                .textCase(nil)
        }
    }
}
