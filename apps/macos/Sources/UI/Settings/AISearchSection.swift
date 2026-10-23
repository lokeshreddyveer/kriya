import SwiftUI

/// Search by meaning: which sources Kriya reads into its local index, where the meaning comes from, and what the index holds.
struct AISearchSection: View {
    @ObservedObject private var indexer = AIIndexer.shared
    @ObservedObject private var store = AIProviderStore.shared
    @State private var confirmDelete = false

    private var embeddingChoices: [AIProviderConfig] {
        store.providers.filter { $0.enabled && ($0.kind == .appleIntelligence || !$0.embeddingModel.isEmpty) }
    }

    var body: some View {
        Section {
            Toggle("Search my notes and other things by meaning", isOn: $indexer.enabled)
            if indexer.enabled {
                Picker("Work out meaning with", selection: Binding(get: { store.embeddingProviderID ?? AIProviderStore.appleID }, set: { store.embeddingProviderID = $0 })) {
                    ForEach(embeddingChoices) { Text($0.name + ($0.isOnThisMac ? " (on this Mac)" : "")).tag($0.id) }
                }
                ForEach(IndexSource.allCases) { source in
                    Toggle(isOn: Binding(get: { indexer.isSourceOn(source) }, set: { indexer.setSource(source, on: $0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.title)
                            Text(source.detail + (indexer.index?.lastIndexed(source).map { " Updated \($0.formatted(.relative(presentation: .named)))." } ?? "")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Update Now") { Task { await indexer.refresh() } }.disabled(indexer.busy)
                    if indexer.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Text("\(indexer.counts.documents) items · \(indexer.counts.chunks) pieces · \(indexer.counts.embedded) with meaning").font(.caption).foregroundStyle(.secondary)
                }
                if let status = indexer.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                Button("Delete the Index…", role: .destructive) { confirmDelete = true }
            }
        } header: { Text("Search by meaning") } footer: {
            Text("Kriya reads the sources you switch on into one file on this Mac (left out of backups), cuts them into pieces, and finds them by words and by meaning. Words-only search needs no AI. Meaning is worked out on this Mac by default; a provider that is not on this Mac gets the text only after you allow it and you must also allow cloud embeddings above. Secrets are hidden before anything is stored. Passwords, the Keychain, private browser windows, API keys and screenshots are never indexed. In the launcher type ? and a question.")
        }
        .confirmationDialog("Delete the search index?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { indexer.deleteIndex() }
        } message: { Text("It is rebuilt from your sources the next time you update it.") }
    }
}
