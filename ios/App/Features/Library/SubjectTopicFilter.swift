import SwiftUI
import CizgiCore

/// The ders/konu filter control shared by "Bilgilerim" and the exercise mode,
/// so the two screens can never offer different filters over the same deck.
///
/// A `Menu` rather than a chip row: eleven subjects and up to twenty-nine
/// topics would take more vertical space than the list they filter.
struct SubjectTopicFilterMenu: View {
    @Binding var subjectFilter: String?
    @Binding var topicFilter: TopicFilter

    private var schema: SubjectTopicSchema? { SubjectTopicSchema.shared }

    var isActive: Bool { subjectFilter != nil || topicFilter != .all }

    var body: some View {
        if let schema {
            Menu {
                Picker("Ders", selection: subjectBinding) {
                    Text("Tüm dersler").tag("")
                    ForEach(schema.subjectNames, id: \.self) { Text($0).tag($0) }
                }

                if let subject = subjectFilter, let topics = schema.topics(for: subject) {
                    Picker("Konu", selection: topicBinding) {
                        Text("Tüm konular").tag(TopicFilter.all)
                        // Everything captured before schema v2.2 lands here.
                        Text("Konusuz").tag(TopicFilter.none)
                        ForEach(topics, id: \.self) { Text($0).tag(TopicFilter.topic($0)) }
                    }
                }
            } label: {
                Label(
                    "Filtrele",
                    systemImage: isActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
            }
        }
    }

    private var subjectBinding: Binding<String> {
        Binding(
            get: { subjectFilter ?? "" },
            set: { newValue in
                subjectFilter = newValue.isEmpty ? nil : newValue
                // A topic only means something inside its subject, and the
                // names are not unique across subjects — carrying one over
                // would filter against a topic the new subject may not have.
                topicFilter = .all
            }
        )
    }

    private var topicBinding: Binding<TopicFilter> {
        Binding(get: { topicFilter }, set: { topicFilter = $0 })
    }
}

/// The active filter, stated in words with a way to clear it. Without this the
/// only sign a filter is on is a filled toolbar icon and a shorter list.
struct ActiveFilterChips: View {
    @Binding var subjectFilter: String?
    @Binding var topicFilter: TopicFilter

    var body: some View {
        if subjectFilter != nil || topicFilter != .all {
            HStack(spacing: Cizgi.Space.xs) {
                if let subject = subjectFilter {
                    TagChip(subject, systemImage: "book")
                }
                switch topicFilter {
                case .all: EmptyView()
                case .none: TagChip("Konusuz", systemImage: "tag.slash")
                case .topic(let topic): TagChip(topic, systemImage: "tag")
                }
                Button {
                    subjectFilter = nil
                    topicFilter = .all
                } label: {
                    Label("Temizle", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Cizgi.muted)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
    }
}
