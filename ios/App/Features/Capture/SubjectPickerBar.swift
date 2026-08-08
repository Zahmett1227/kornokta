import SwiftUI
import CizgiCore

/// The sticky subject (ders) strip on the capture tab (schema v2.2).
///
/// Backed by the same `AppSettings.defaultSubject` the Settings picker edits —
/// one stored value, two views of it — so a tap here persists immediately and
/// survives app restarts. Tapping the selected chip again does not deselect:
/// clearing the subject is a rarer act and stays in Settings ("Seçilmedi").
///
/// Renders nothing when the bundled subject list failed to load; a capture
/// without a subject is degraded, not broken.
struct SubjectPickerBar: View {
    @EnvironmentObject private var environment: AppEnvironment

    /// Loaded once per process; the bundled resource cannot change mid-run.
    static let schema = SubjectTopicSchema.shared

    /// The canonical form of a stored subject, or nil when it is blank or not
    /// a name the template knows. The one place capture, Settings and the
    /// filters agree on what a subject string means.
    static func canonicalSubject(_ raw: String?) -> String? {
        schema?.canonicalSubject(matching: raw)
    }

    var body: some View {
        if let schema = Self.schema {
            VStack(alignment: .leading, spacing: Cizgi.Space.xs) {
                Text("Ders")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Cizgi.Space.xs) {
                            ForEach(schema.subjectNames, id: \.self) { name in
                                // Compared canonically so a legacy free-text
                                // value like "patoloji" still lights its chip.
                                chip(name, isSelected: name == selectedSubject)
                            }
                        }
                    }
                    .onAppear {
                        guard let selected = selectedSubject else { return }
                        proxy.scrollTo(selected, anchor: .center)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectedSubject: String? {
        Self.canonicalSubject(environment.settings.defaultSubject)
    }

    private func chip(_ name: String, isSelected: Bool) -> some View {
        Button {
            environment.settings.defaultSubject = name
            environment.settings.save()
        } label: {
            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(isSelected ? Cizgi.paper : Cizgi.ink)
                .padding(.horizontal, Cizgi.Space.sm)
                .padding(.vertical, Cizgi.Space.xs)
                .background(isSelected ? Cizgi.accent : Cizgi.accentSoft, in: Capsule())
        }
        .buttonStyle(.plain)
        .id(name)
    }
}
