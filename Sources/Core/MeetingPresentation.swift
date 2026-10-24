import Foundation

/// User-facing meeting states, shared by the list and detail view. Processing
/// and recovery decisions still belong to the engine and scheduler.
public enum MeetingPresentation {
    public static func status(_ meeting: Meeting, work: ProcessingWorkState? = nil, compact: Bool = false) -> String {
        switch meeting.status {
        case .recording: return "Recording"
        case .processing:
            if let work, work != .running { return compact ? "Waiting" : work.description }
            return "Preparing notes"
        case .summarized: return "Summary ready"
        case .failed: return meeting.processingRequest == nil ? "Needs attention" : "Ready to resume"
        }
    }

    public static func activity(_ stage: ProcessingStage) -> String {
        switch stage {
        case .transcribing: return "Creating your transcript…"
        case .diarizing: return "Identifying speakers…"
        case .summarizing: return "Writing your summary…"
        }
    }

    public static func recovery(_ meeting: Meeting) -> String {
        if meeting.summary != nil, !meeting.pendingArtifactDeletion.isEmpty {
            return "Your summary is saved. Try again to finish removing files according to your storage settings."
        }
        if meeting.processingRequest != nil {
            return "Choose Resume to try again with your earlier settings. To use your current settings, cancel this attempt first."
        }
        if !meeting.transcript.isEmpty {
            return meeting.audioFileURLs.isEmpty
                ? "Your transcript is saved. Try again to finish the summary."
                : "Your transcript is saved. Try again to finish the summary, or choose Transcribe again to start over from the recording."
        }
        if !meeting.audioFileURLs.isEmpty {
            return "Try again to create notes from your saved recording. You can review your recording and summary options in Settings."
        }
        return "Check your audio sources and permissions before starting another recording."
    }

    public static func settingsChanged(_ meeting: Meeting, current: AppSettings) -> Bool {
        guard let saved = meeting.processingRequest?.settings else { return false }
        return saved.transcriptionBackend != current.transcriptionBackend || saved.whisperModel != current.whisperModel ||
            saved.summaryBackend != current.summaryBackend || saved.summaryModel != current.summaryModel ||
            saved.language != current.language || saved.transcriptionVocabulary != current.transcriptionVocabulary ||
            saved.keepAudioAfterSummary != current.keepAudioAfterSummary || saved.keepTranscriptAfterSummary != current.keepTranscriptAfterSummary
    }
}
