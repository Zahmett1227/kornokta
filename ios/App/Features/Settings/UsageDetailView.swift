import SwiftUI
import SwiftData
import CizgiCore

/// Ayarlar → Kullanım → "Çağrı dökümü": every provider call, priced (§16.8).
///
/// The summary above it answers "how much", this answers "on what". Both were
/// unanswerable while only successful calls were written down, and the second
/// question is the one that leads somewhere: a screen full of
/// `incomplete_max_output_tokens` says raise the ceiling or cut the card count,
/// a screen full of `timeout` says the pages are too dense for the time budget,
/// and a screen of clean successes says the money is simply the work.
///
/// The per-model section is the measurement a model change needs. Running a
/// week on one tier and a week on another puts two rows side by side with real
/// money on them, which is the only way to answer "does the cheaper tier cost
/// me quality on *my* pages?" without guessing.
struct UsageDetailView: View {
    /// Newest first: the calls worth explaining are almost always the recent
    /// ones, and the list is unbounded in principle.
    @Query(sort: \ModelRun.createdAt, order: .reverse) private var runs: [ModelRun]

    var body: some View {
        List {
            let entries = runs.map(SettingsView.entry(for:))
            let byModel = UsageSummary.byModel(entries)

            if byModel.count > 1 {
                Section {
                    ForEach(byModel, id: \.model) { row in
                        LabeledContent(row.model.isEmpty ? "(bilinmiyor)" : row.model) {
                            Text("\(row.summary.callCount) çağrı · \(SettingsView.usd(row.summary.totalCostUSD))")
                                .foregroundStyle(Cizgi.muted)
                        }
                    }
                } header: {
                    Text("Modele göre")
                } footer: {
                    Text("Model değiştirdiğinde iki satırı yan yana oku: çağrı sayısı "
                         + "benzerken maliyet farkı, o modelin sana gerçek faturası.")
                }
            }

            let summary = UsageSummary.of(entries)
            if summary.inputTokens > 0 || summary.outputTokens > 0 {
                Section {
                    LabeledContent("Girdi token", value: summary.inputTokens.formatted())
                    LabeledContent("— önbellekten") {
                        Text("\(summary.cachedInputTokens.formatted()) (%\(Self.percent(summary.cacheHitShare)))")
                            .foregroundStyle(Cizgi.muted)
                    }
                    LabeledContent("Çıktı token", value: summary.outputTokens.formatted())
                    LabeledContent("— düşünme (reasoning)") {
                        Text("\(summary.reasoningTokens.formatted()) (%\(Self.percent(summary.reasoningShare)))")
                            .foregroundStyle(Cizgi.muted)
                    }
                } header: {
                    Text("Token kırılımı")
                } footer: {
                    // Both shares are subsets, and both are levers: cached
                    // input is billed at a fraction of the rate, and reasoning
                    // is billed at the output rate — the most expensive one.
                    Text("Önbellekten gelen girdi çok daha ucuz faturalanır. Düşünme "
                         + "tokenları çıktının içindedir ve en pahalı fiyattan sayılır — "
                         + "kart üretimine değil, modelin kendi düşünmesine giden pay.")
                }
            }

            Section("Çağrılar") {
                if runs.isEmpty {
                    Text("Henüz model çağrısı yok.")
                        .foregroundStyle(Cizgi.muted)
                } else {
                    ForEach(runs) { run in
                        row(run)
                    }
                }
            }
        }
        .navigationTitle("Çağrı dökümü")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func row(_ run: ModelRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Never colour alone (§29): the icon and the trailing text both
                // carry the outcome.
                Label(Self.outcomeText(run), systemImage: Self.outcomeIcon(run))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Self.outcomeTint(run))
                Spacer()
                Text(Self.costText(run))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Cizgi.ink)
            }

            Text(Self.subtitle(run))
                .font(.caption)
                .foregroundStyle(Cizgi.muted)

            if run.inputTokens > 0 || run.outputTokens > 0 {
                Text(Self.tokenText(run))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Cizgi.muted)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    static func outcomeText(_ run: ModelRun) -> String {
        if run.success { return "Başarılı" }
        // The machine reason is shown as-is rather than translated: it is the
        // string the server and the logs use, so searching for it works.
        return run.failureReason.map { "Başarısız · \($0)" } ?? "Başarısız"
    }

    static func outcomeIcon(_ run: ModelRun) -> String {
        if run.success { return "checkmark.circle.fill" }
        return run.billing == ModelRunBilling.none
            ? "slash.circle"
            : "exclamationmark.triangle.fill"
    }

    static func outcomeTint(_ run: ModelRun) -> Color {
        if run.success { return Cizgi.success }
        // A rejected call is grey, not red: it cost nothing, and colouring it
        // like a burned generation would make the list look alarming in exactly
        // the place there is nothing to fix.
        return run.billing == ModelRunBilling.none ? Cizgi.muted : Cizgi.danger
    }

    /// "Ölçülemedi" rather than 0.0000 USD: the call was billed, we simply
    /// never learned the amount, and a zero here would read as free (§0.6).
    static func costText(_ run: ModelRun) -> String {
        switch run.billing {
        case ModelRunBilling.unmeasured: return "ölçülemedi"
        case ModelRunBilling.none: return "ücretsiz"
        default: return SettingsView.usd(run.estimatedCostUSD)
        }
    }

    static func subtitle(_ run: ModelRun) -> String {
        var parts: [String] = []
        if !run.model.isEmpty { parts.append(run.model) }
        parts.append(Self.purposeLabel(run.purpose))
        if run.attempt > 0 { parts.append("\(run.attempt). deneme") }
        parts.append("\(run.latencyMs / 1000) sn")
        parts.append(run.createdAt.formatted(.dateTime.day().month().hour().minute()))
        return parts.joined(separator: " · ")
    }

    /// Turkish name for a ledger entry's `purpose`.
    ///
    /// A switch rather than the ternary this replaced: with two purposes the
    /// ternary was fine, but its `else` silently labelled *anything* new as
    /// "kart üretimi", so a third purpose would have shown up on the cost screen
    /// wearing the wrong name and nothing would have gone red. The default now
    /// prints the raw value, which is ugly on purpose — an unlabelled purpose
    /// should look like a missing case, not like card generation.
    static func purposeLabel(_ purpose: String) -> String {
        switch purpose {
        case "card_generation": return "kart üretimi"
        case "second_opinion": return "ikinci görüş"
        case "dark_map": return "karanlık harita"
        default: return purpose
        }
    }

    static func tokenText(_ run: ModelRun) -> String {
        var input = "girdi \(run.inputTokens.formatted())"
        if run.cachedInputTokens > 0 {
            input += " (\(run.cachedInputTokens.formatted()) önbellek)"
        }
        var output = "çıktı \(run.outputTokens.formatted())"
        if run.reasoningTokens > 0 {
            output += " (\(run.reasoningTokens.formatted()) düşünme)"
        }
        return "\(input) · \(output)"
    }

    static func percent(_ share: Double) -> Int {
        Int((share * 100).rounded())
    }
}
