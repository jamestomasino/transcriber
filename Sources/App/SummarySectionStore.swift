import Foundation
import CryptoKit
#if canImport(TranscriberCore)
import TranscriberCore
#endif

/// Partial notes follow managed meeting retention, never the model cache.
/// Callers supply a URL only when transcript retention was explicitly enabled.
/// No prompt or transcript is stored here: keys are digests of exact inputs.
final class SummarySectionStore: @unchecked Sendable {
    private struct Payload: Codable {
        let version: Int
        var sections: [String: MeetingSummary]
    }
    private let lock = NSLock()
    private let url: URL?
    private var sections: [String: MeetingSummary] = [:]
    init(url: URL?) {
        self.url = url
        if let url, let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
           size.intValue <= 8 * 1_024 * 1_024,
           let bytes = try? Data(contentsOf: url), let payload = try? JSONDecoder().decode(Payload.self, from: bytes),
           payload.version == 1, payload.sections.count <= 256 {
            sections = payload.sections
        }
    }
    static func key(modelHash: String, title: String, segments: [TranscriptSegment], maximumOutputTokens: Int) throws -> String {
        // Bump the namespace whenever prompt, schema, chunking or sampling
        // semantics change. Include the complete ordered request text, not IDs.
        let object: [String: Any] = ["version": "meeting-notes-v1-temp0.1-nothinking-schema1",
            "model": modelHash, "title": title, "transcript": Summary.transcriptText(segments),
            "prompt": Summary.prompt(title: title, transcript: Summary.transcriptText(segments)),
            "systemInstruction": LocalJSONSummarizer.systemInstruction,
            "schema": LocalJSONSummarizer.responseSchema(),
            "contextTokens": SummaryModelCatalog.contextTokens, "outputTokens": maximumOutputTokens]
        return SHA256.hash(data: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)).map { String(format: "%02x", $0) }.joined()
    }
    func load(_ key: String, segments: [TranscriptSegment]) -> MeetingSummary? {
        lock.lock(); defer { lock.unlock() }
        guard let value = sections[key], !value.overall.isEmpty,
              (try? Summary.validateDetail(value, segments: segments)) != nil else { return nil }
        return value
    }
    func save(_ value: MeetingSummary, key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if sections.count >= 256, sections[key] == nil { return }
        sections[key] = value
        guard let url else { return }
        let bytes = try JSONEncoder().encode(Payload(version: 1, sections: sections))
        guard bytes.count <= 8 * 1_024 * 1_024 else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func remove() throws {
        lock.lock(); defer { lock.unlock() }
        sections = [:]
        if let url, FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

struct ReusingSectionSummarizer: Summarizer {
    let inner: LocalJSONSummarizer
    let cache: SummarySectionStore
    let modelHash: String
    func summarize(segments: [TranscriptSegment], title: String) async throws -> MeetingSummary {
        let key = try SummarySectionStore.key(modelHash: modelHash, title: title, segments: segments, maximumOutputTokens: inner.maximumOutputTokens)
        if let saved = cache.load(key, segments: segments) {
            await ProcessingMeasurements.shared.record("summary.sectionReused", seconds: 0)
            return saved
        }
        let summary = try await inner.summarize(segments: segments, title: title)
        try Task.checkCancellation()
        try Summary.validateDetail(summary, segments: segments)
        try cache.save(summary, key: key)
        return summary
    }
}
