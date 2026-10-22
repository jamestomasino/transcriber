import Foundation

// MARK: - Summary prompt + parser (Core, pure)
//
// Shared by every LLM summarizer backend (OpenAI, Anthropic). The prompt asks
// for a strict JSON object; the parser is lenient (extracts the JSON object
// from a markdown-fenced or prose-wrapped response, tolerates missing fields)
// so a slightly-off model still yields a usable summary. Pure → unit-testable
// in Core without any network.

public enum Summary {
    /// Build the transcript text from speaker-labeled segments.
    public static func transcriptText(_ segments: [TranscriptSegment]) -> String {
        segments.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    /// The character budget a transcript is fit into before it goes to the LLM.
    /// Generous on purpose: a 1–2 hour meeting's transcript (~40–90k chars)
    /// passes through untouched, while a very long recording (hours) is capped
    /// so the prompt stays inside the model's context window and its cost —
    /// instead of failing the summary outright with a 400. This is the "cap on
    /// very long recordings" half of the long-meeting risk.
    public static let defaultTranscriptBudget = 120_000

    /// Fit a transcript into a character budget, keeping the **opening** (where
    /// the agenda and context live) and the **closing** (where decisions and
    /// action items usually land), and marking the omission in between. Short
    /// transcripts (within the budget) are returned unchanged. Pure and
    /// deterministic, so it is unit-testable and the head/tail split is stable.
    public static func fitTranscript(
        _ transcript: String,
        budget: Int = defaultTranscriptBudget
    ) -> String {
        if transcript.count <= budget { return transcript }
        let marker = "\n…(middle of transcript omitted)…\n"
        let available = max(budget - marker.count, 1)
        let headLen = (available * 60) / 100
        let tailLen = available - headLen
        let head = String(transcript.prefix(headLen))
        let tail = String(transcript.suffix(tailLen))
        return head + marker + tail
    }

    /// The user-facing prompt. Asks for a compact JSON summary.
    public static func prompt(title: String, transcript: String) -> String {
        """
        You are a meeting assistant. Summarize the following meeting transcript.

        Meeting title: \(title.isEmpty ? "(untitled)" : title)

        Transcript:
        \(transcript.isEmpty ? "(no speech captured)" : transcript)

        Respond with ONLY a JSON object, no prose, in exactly this shape:
        {
          "overall": "2-4 sentence summary of what happened and the outcome",
          "key_points": ["key point 1", "key point 2"],
          "decisions": ["decision 1", "decision 2"],
          "action_items": ["who: what by when", ...]
        }
        Use empty arrays if a category has nothing. Do not invent details that are not in the transcript.
        """
    }

    /// Parse a model response into a `MeetingSummary`. Lenient: finds the first
    /// balanced JSON object in the text (handles ```json fences and surrounding
    /// prose) and tolerates missing fields.
    public static func parse(_ raw: String) -> MeetingSummary {
        guard let json = extractJSONObject(in: raw),
              let data = json.data(using: .utf8)
        else {
            // Fallback: treat the whole response as the overall summary.
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return MeetingSummary(overall: trimmed.isEmpty ? "(no summary produced)" : trimmed)
        }

        let decoder = JSONDecoder()
        struct M: Decodable {
            let overall: String?
            let key_points: [String]?
            let keyPoints: [String]?
            let decisions: [String]?
            let action_items: [String]?
            let actionItems: [String]?
        }
        guard let m = try? decoder.decode(M.self, from: data) else {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return MeetingSummary(overall: trimmed.isEmpty ? "(no summary produced)" : trimmed)
        }

        return MeetingSummary(
            overall: m.overall?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            keyPoints: (m.key_points ?? m.keyPoints ?? []),
            decisions: m.decisions ?? [],
            actionItems: (m.action_items ?? m.actionItems ?? [])
        )
    }

    /// Find the first balanced top-level JSON object in `text`. Returns it as a
    /// string, or nil. Handles ```json fences and leading/trailing prose.
    private static func extractJSONObject(in text: String) -> String? {
        // Strip a ```json ... ``` fence if present.
        var s = text
        if let fence = s.range(of: "```") {
            s = String(s[fence.upperBound...])
            if let close = s.range(of: "```") { s = String(s[..<close.lowerBound]) }
        }
        // Find the first '{' and balance to its matching '}'.
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escape { escape = false }
                else if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(s[start...i])
                    }
                default: break
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
