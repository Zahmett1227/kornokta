import SwiftUI
import SwiftData
import CizgiCore
#if canImport(UIKit)
import UIKit
#endif

/// "Kaynağı göster" (ANA-PLAN §5.5).
///
/// The action existed but could never fire: it was gated on `card.sourceQuote`,
/// and the Faz 6 vision contract has no per-card quote — `BackendCardProvider`
/// sets it to `""` on every card it makes. So the one thing a doctor wants from
/// a card they doubt ("where did this come from?") was unreachable, even though
/// the photograph was sitting on disk the whole time and the relationship chain
/// to it was intact: `Card → KnowledgeUnit → TextRegion → CapturedPage`.
///
/// What it can honestly show in Faz 6 is the marked page itself and what the
/// model reported reading off it. §5.5 also asks for a crop and book/page
/// details; neither exists on this path — the vision flow produces one full-page
/// region and nothing ever fills `pageNumber` — so neither is invented here.
struct CardSourceView: View {
    let material: CardSourceMaterial
    let imageStore: ImageStore

    /// Built in one place so the review screen and the detail screen can never
    /// disagree about a card's provenance.
    static func material(for card: Card, imageStore: ImageStore) -> CardSourceMaterial {
        let page = card.knowledgeUnit?.region?.page
        let path = page?.originalImagePath
        return CardSourceResolver.material(
            cardFront: card.front,
            quote: card.sourceQuote,
            readText: card.knowledgeUnit?.canonicalClaim,
            subject: card.knowledgeUnit?.subject,
            pageImagePath: path,
            // The record keeps its path after "Orijinal sayfayı sakla" is turned
            // off, so the file has to be asked about rather than assumed.
            pageImageExists: path.map { imageStore.exists(relativePath: $0) } ?? false,
            capturedAt: page?.captureDate
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Cizgi.Space.md) {
            if let path = material.pageImagePath, let image = loadImage(path) {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous)
                            .stroke(Cizgi.hairline, lineWidth: 1)
                    )
            } else if material.pageImageDiscarded {
                Label(
                    "Orijinal sayfa saklanmıyor (Ayarlar → Veri).",
                    systemImage: "photo.badge.exclamationmark"
                )
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
            }

            if let readText = material.readText {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Modelin okuduğu")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Cizgi.muted)
                    Text(readText)
                        .font(.footnote)
                        .foregroundStyle(Cizgi.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let quote = material.quote {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kaynak alıntısı")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Cizgi.muted)
                    Text(quote)
                        .font(.footnote)
                        .foregroundStyle(Cizgi.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if material.subject != nil || material.capturedAt != nil {
                HStack(spacing: Cizgi.Space.sm) {
                    if let subject = material.subject {
                        TagChip(subject)
                    }
                    if let capturedAt = material.capturedAt {
                        Text(capturedAt.formatted(.dateTime.day().month().year()))
                            .font(.caption)
                            .foregroundStyle(Cizgi.muted)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadImage(_ path: String) -> Image? {
        guard let data = try? imageStore.load(relativePath: path) else { return nil }
        #if canImport(UIKit)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #else
        return nil
        #endif
    }
}
