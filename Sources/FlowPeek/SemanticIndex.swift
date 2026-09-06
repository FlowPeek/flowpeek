import FlowPeekCore
import Foundation
import NaturalLanguage

/// Meaning, computed on this Mac.
///
/// `NLEmbedding` ships with macOS and runs entirely on the device, which is the only way FlowPeek
/// can offer a search by meaning at all: sending somebody's diagrams to a provider to find one of
/// them again would undo the thing the rest of the app is careful about. Nothing here touches the
/// network, and nothing is written down -- the vectors live for as long as the shelf is open.
///
/// Apple ships sentence embeddings for a handful of languages and no others. When there is no
/// model for what was typed -- Korean, at the time of writing -- `distance` answers nil, the
/// ranking keeps only its literal matches, and the search still works, just less cleverly. That is
/// the whole of the fallback: no second-guessing, no translation, no pretending.
final class SemanticIndex: DiagramSemanticIndex, @unchecked Sendable {
    /// One model per language, made on first use: loading one is tens of milliseconds and a shelf
    /// that stutters on the first keystroke is a shelf people stop typing into.
    private var models: [NLLanguage: NLEmbedding?] = [:]
    private let lock = NSLock()

    func distance(_ query: String, _ candidate: String) -> Double? {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: query),
              let embedding = model(for: language) else { return nil }
        let distance = embedding.distance(between: query, and: candidate, distanceType: .cosine)
        // `NLEmbedding` answers 2.0 -- the far end of a cosine distance -- for text it could not
        // place at all, which is not a neighbour however the threshold is set.
        guard distance.isFinite, distance < 2 else { return nil }
        return distance
    }

    private func model(for language: NLLanguage) -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = models[language] { return cached }
        let embedding = NLEmbedding.sentenceEmbedding(for: language)
        models[language] = embedding
        return embedding
    }
}
