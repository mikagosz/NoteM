import Foundation
import NaturalLanguage

/// Indeks semantyczny (Priorytet 3): dla każdej notatki trzyma wektor
/// znaczeniowy liczony on-device przez `NLContextualEmbedding` (wielojęzyczny
/// model Apple — obsługuje polski, w przeciwieństwie do `NLEmbedding`).
/// Wyszukiwanie "znaczeniowe" porównuje wektor zapytania z wektorami notatek
/// (cosine similarity) i zwraca najlepsze dopasowania.
///
/// Wektory są cache'owane w `semantic_index.json` w katalogu notatnika i
/// przeliczane przyrostowo — tylko dla notatek, których treść się zmieniła
/// (porównanie po stabilnym hashu FNV-1a, bo `hashValue` Swifta zmienia się
/// między uruchomieniami).
actor SemanticIndex {
    private struct Entry: Codable {
        var hash: UInt64
        var vector: [Float]
    }

    private var entries: [UUID: Entry] = [:]
    private var indexURL: URL?
    private var dirty = false
    /// Loaded lazily on first use; `nil` after a failed load means the model
    /// isn't available on this Mac — semantic search then silently disables.
    private var model: NLContextualEmbedding?
    private var modelLoadFailed = false

    /// Embedding input is capped so very long notes don't blow the model's
    /// sequence limit; the opening of a note carries most of its meaning.
    private static let maxTextLength = 1500

    // MARK: - Setup & cache

    /// Points the index at its cache file and loads previously computed
    /// vectors. Safe to call again when the store root moves.
    func configure(indexURL: URL) {
        self.indexURL = indexURL
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([UUID: Entry].self, from: data) else { return }
        entries = decoded
    }

    private func saveIfNeeded() {
        guard dirty, let indexURL else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
        dirty = false
    }

    // MARK: - Indexing

    /// Recomputes vectors for new/changed notes and drops entries of deleted
    /// ones. Call with every note's `title + content`; cheap when nothing
    /// changed thanks to the hash check.
    func reindex(_ items: [(id: UUID, text: String)]) {
        guard let model = loadedModel() else { return }
        var seen = Set<UUID>()
        for (id, text) in items {
            seen.insert(id)
            let hash = Self.fnv1a(text)
            if entries[id]?.hash == hash { continue }
            guard let vector = embed(text, with: model) else { continue }
            entries[id] = Entry(hash: hash, vector: vector)
            dirty = true
        }
        for id in entries.keys where !seen.contains(id) {
            entries.removeValue(forKey: id)
            dirty = true
        }
        saveIfNeeded()
    }

    // MARK: - Search

    /// Notes ranked by semantic closeness to the query, best first.
    /// Empty when the model is unavailable or nothing is indexed yet.
    func search(_ query: String, topN: Int = 15) -> [UUID] {
        guard let model = loadedModel(), let queryVector = embed(query, with: model) else { return [] }
        return entries
            .map { (id: $0.key, score: Self.cosine($0.value.vector, queryVector)) }
            .sorted { $0.score > $1.score }
            .prefix(topN)
            .map(\.id)
    }

    // MARK: - Model & math

    private func loadedModel() -> NLContextualEmbedding? {
        if let model { return model }
        guard !modelLoadFailed else { return nil }
        // The Latin-script model is multilingual, so one instance covers both
        // Polish and English notes.
        guard let embedding = NLContextualEmbedding(language: .polish),
              embedding.hasAvailableAssets,
              (try? embedding.load()) != nil else {
            modelLoadFailed = true
            return nil
        }
        model = embedding
        return embedding
    }

    /// Mean-pooled token vectors for the (truncated) text, or `nil` when the
    /// model can't process it.
    private func embed(_ text: String, with model: NLContextualEmbedding) -> [Float]? {
        let trimmed = String(text.prefix(Self.maxTextLength))
        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let result = try? model.embeddingResult(for: trimmed, language: .polish) else { return nil }
        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            for (i, value) in vector.enumerated() { sum[i] += value }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        return sum.map { Float($0 / Double(count)) }
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        let denominator = (na.squareRoot() * nb.squareRoot())
        return denominator > 0 ? dot / denominator : -1
    }

    /// Stable 64-bit FNV-1a hash of the text's UTF-8 bytes.
    private static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
