import Foundation

/// Deterministic cleanup, without a model call or speculative word correction.
/// Keep small timed segments for voice matching; use paragraphs for reading and
/// summarization. Only time-qualified overlap can justify deleting speech.
public enum TranscriptCleanup {
    public static let maximumParagraphCharacters = 1_200
    public static let maximumParagraphSeconds: TimeInterval = 60
    private struct Token {
        let key: String
        let range: Range<String.Index>
    }
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"[\p{L}\p{N}]+(?:['’./:_-][\p{L}\p{N}]+)*|[\p{Sc}\p{Sm}%\-°@#&*/^]"#)
    private static let negations: Set<String> = ["not", "no", "never", "without", "cannot", "can't", "don't", "doesn't", "didn't", "won't", "isn't", "wasn't", "shouldn't", "couldn't", "wouldn't"]
    private static let units: Set<String> = ["g", "mg", "kg", "ug", "µg", "μg", "l", "ml", "m", "mm", "s", "ms", "w", "kw", "mw", "hz", "mhz", "ghz", "pa", "mpa", "b", "kb", "mb", "gb", "tb", "mbps", "gbps", "mol", "mmol"]

    public static func readable(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        paragraphs(deduplicated(segments))
    }

    public static func deduplicated(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for original in segments {
            var segment = original
            segment.text = original.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !segment.text.isEmpty else { continue }
            guard validTime(segment), segment.speaker != SpeakerAlignment.unknownSpeaker,
                  let previous = result.last, previous.speaker == segment.speaker, validTime(previous) else {
                result.append(segment); continue
            }
            let current = tokens(segment.text)
            guard !current.isEmpty else { result.append(segment); continue }
            let last = tokens(previous.text)
            // An exactly repeated timestamped line is safe even for a single
            // word. Sequential "yes, yes" and other spoken repetition survive.
            if current.map(\.key) == last.map(\.key),
               abs(segment.startOffset - previous.startOffset) <= 0.15,
               abs(segment.endOffset - previous.endOffset) <= 0.15 {
                result[result.count - 1].endOffset = max(previous.endOffset, segment.endOffset)
                continue
            }
            // Known sections with the same origin have no section-replay
            // evidence. Preserve repeated statements inside that section.
            if let a = previous.audioSectionStart, let b = segment.audioSectionStart, a == b {
                result.append(segment); continue
            }
            var recent: [TranscriptSegment] = []
            for old in result.reversed().prefix(16) {
                guard old.speaker == segment.speaker, validTime(old), old.endOffset >= segment.startOffset - 0.3 else { break }
                recent.append(old)
            }
            recent.reverse()
            let end = recent.map(\.endOffset).max() ?? previous.endOffset
            let overlap = max(0, min(end, segment.endOffset) - segment.startOffset)
            let sectionReplay: Bool
            if let start = segment.audioSectionStart, let old = previous.audioSectionStart {
                sectionReplay = start.isFinite && start > old && segment.startOffset >= start &&
                    segment.startOffset <= start + 2 && previous.endOffset >= start &&
                    previous.endOffset <= start + 2.3 && segment.startOffset <= previous.endOffset + 0.25
            } else { sectionReplay = false }
            guard overlap >= 0.35 || sectionReplay else { result.append(segment); continue }

            // Some older transcripts were timestamp-sorted at a section edge:
            // a short duplicate can follow a longer line containing that text.
            // Check the approximate phrase location, not arbitrary text anywhere
            // in a long paragraph whose last seconds happen to overlap.
            var contained = false
            if substantial(current.map(\.key)) {
                for old in recent {
                    let oldTokens = tokens(old.text)
                    guard oldTokens.count >= current.count else { continue }
                    let keys = current.map(\.key)
                    for index in 0...(oldTokens.count - current.count) {
                        guard Array(oldTokens[index..<(index + current.count)].map(\.key)) == keys else { continue }
                        if changesNegation(context: Array(oldTokens.prefix(index).suffix(3).map(\.key)), matched: keys) { continue }
                        let duration = old.endOffset - old.startOffset
                        let phraseStart = old.startOffset + duration * Double(index) / Double(oldTokens.count)
                        let phraseEnd = old.startOffset + duration * Double(index + current.count) / Double(oldTokens.count)
                        let phraseOverlap = min(phraseEnd, segment.endOffset) - max(phraseStart, segment.startOffset)
                        let coverage = (min(old.endOffset, segment.endOffset) - max(old.startOffset, segment.startOffset)) / (segment.endOffset - segment.startOffset)
                        if phraseOverlap >= 0.25 && coverage >= 0.6 { contained = true; break }
                    }
                    if contained { break }
                }
            }
            if contained { continue }

            let tail = Array(recent.flatMap { tokens($0.text).map(\.key) }.suffix(96))
            let limit = min(64, tail.count, current.count)
            var matched = 0
            if limit >= 3 {
                for count in stride(from: limit, through: 3, by: -1) {
                    let prefix = Array(current.prefix(count).map(\.key))
                    if substantial(prefix), Array(tail.suffix(count)) == prefix,
                       !changesNegation(context: Array(tail.dropLast(count).suffix(3)), matched: prefix) { matched = count; break }
                }
            }
            let replayDuration = sectionReplay ? max(2, overlap) : overlap
            let prefixDuration = (segment.endOffset - segment.startOffset) * Double(matched) / Double(current.count)
            guard matched > 0, prefixDuration <= replayDuration + 0.35 else { result.append(segment); continue }
            if matched == current.count {
                let coverage = overlap / (segment.endOffset - segment.startOffset)
                if coverage >= 0.6 || (sectionReplay && coverage >= 0.4) { continue }
            } else if segment.endOffset > end {
                segment.text = String(segment.text[current[matched].range.lowerBound...])
                segment.startOffset = max(segment.startOffset, end)
                // This is now a non-overlapping continuation, not a replayable
                // raw section edge. Clearing provenance makes cleanup idempotent.
                segment.audioSectionStart = nil
            }
            result.append(segment)
        }
        return result
    }

    public static func paragraphs(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments {
            guard let previous = result.last, previous.speaker == segment.speaker,
                  segment.speaker != SpeakerAlignment.unknownSpeaker,
                  validTime(previous), validTime(segment),
                  segment.startOffset >= previous.startOffset,
                  segment.startOffset - previous.endOffset <= 2,
                  max(previous.endOffset, segment.endOffset) - previous.startOffset <= maximumParagraphSeconds,
                  previous.text.count + segment.text.count + 1 <= maximumParagraphCharacters else {
                result.append(segment); continue
            }
            result[result.count - 1].text += " " + segment.text
            result[result.count - 1].endOffset = max(previous.endOffset, segment.endOffset)
            if previous.audioSectionStart != segment.audioSectionStart { result[result.count - 1].audioSectionStart = nil }
        }
        return result
    }
    private static func validTime(_ segment: TranscriptSegment) -> Bool {
        segment.startOffset.isFinite && segment.endOffset.isFinite && segment.startOffset >= 0 && segment.endOffset > segment.startOffset
    }
    private static func substantial(_ keys: [String]) -> Bool { keys.count >= 3 && keys.joined().count >= 12 }
    private static func changesNegation(context: [String], matched: [String]) -> Bool {
        !negations.isDisjoint(with: context) && negations.isDisjoint(with: matched)
    }
    private static func tokens(_ text: String) -> [Token] {
        tokenPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            let literal = String(text[range]).precomposedStringWithCanonicalMapping.replacingOccurrences(of: "’", with: "'")
            let lower = literal.lowercased()
            let preserveCase = units.contains(lower) || literal.rangeOfCharacter(from: .decimalDigits) != nil
            return Token(key: preserveCase ? literal : lower, range: range)
        }
    }
}
