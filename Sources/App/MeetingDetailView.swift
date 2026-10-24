import SwiftUI

#if canImport(TranscriberCore)
import TranscriberCore
#endif

// MARK: - Meeting detail (App)
//
// The read-out for a single meeting: the full structured summary (overall,
// key points, decisions, action items), the retained transcript (when the
// user opted to keep it), and the actions that matter for its lifecycle —
// Retry (failed), Copy summary / transcript, and Delete.
//
// The copyable text comes from the pure Core helpers `summaryText()` /
// `transcriptText()`, so the on-screen rendering and the clipboard share one
// deterministic source. This view itself is App-layer (SwiftUI + AppKit
// clipboard); the data + text formatting stay pure in Core.
struct MeetingDetailView: View {
    @ObservedObject var vm: TranscriberViewModel
    let meeting: Meeting

    @State private var copied: String? = nil
    @State private var retrying: Bool = false
    @State private var confirmDelete = false

    /// The meeting as it currently stands (it can change while we're looking
    /// at it — e.g. retry flips failed → summarized). Re-read from the VM so
    /// the view tracks live state rather than a stale copy.
    private var live: Meeting? { vm.meetings.first(where: { $0.id == meeting.id }) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                if live?.status == .failed {
                    failedBody
                } else if live?.status == .processing || live?.status == .recording {
                    inFlightBody
                } else if let s = live?.summary {
                    summaryBody(s)
                } else {
                    emptyBody
                }
                if let t = live?.transcript, !t.isEmpty {
                    Divider()
                    transcriptBody(t)
                }
                Divider()
                actions
            }
            .padding(16)
        }
        .textSelection(.enabled)
        .frame(minWidth: 380, maxWidth: .infinity)
        .confirmationDialog("Delete this meeting and its retained audio and transcript?", isPresented: $confirmDelete) {
            Button("Delete meeting", role: .destructive) { vm.delete(id: meeting.id) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(live?.title ?? meeting.title)
                    .font(.title2.bold())
                Spacer()
                statusBadge
            }
            HStack(spacing: 12) {
                Label(dateString, systemImage: "calendar")
                Label(durationString, systemImage: "clock")
                if let n = live?.speakerCount, n > 0 {
                    Label(live?.speakerAttribution == .unverified ? "Speaker labels unverified" : "\(n) \(live?.speakerAttribution == .voiceClustering ? "estimated " : "")speaker\(n == 1 ? "" : "s")", systemImage: "person.2")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var statusBadge: some View {
        let status = live?.status ?? meeting.status
        let (text, color): (String, Color)
        switch status {
        case .recording:  (text, color) = ("Recording", .orange)
        case .processing: (text, color) = ("Processing…", .blue)
        case .summarized: (text, color) = ("Summarized", .green)
        case .failed:     (text, color) = ("Failed", .red)
        }
        return Text(status.rawValue)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: - Summary body

    @ViewBuilder
    private func summaryBody(_ s: MeetingSummary) -> some View {
        SectionText("Summary")
        if s.transcriptWasCapped {
            Label("This meeting was long, so the summary reflects only the opening and closing of the transcript (the middle was omitted).",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
        }
        if !s.model.isEmpty { Text("Summary model: \(s.model)").font(.caption).foregroundStyle(.secondary) }
        Text(s.overall.isEmpty ? "—" : s.overall)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
        if !s.keyPoints.isEmpty {
            SectionText("Key points")
            bulletList(s.keyPoints)
        }
        if !s.decisions.isEmpty {
            SectionText("Decisions")
            bulletList(s.decisions)
        }
        if !s.actionItems.isEmpty {
            SectionText("Action items")
            bulletList(s.actionItems)
        }
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(item).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
    }

    private func SectionText(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.top, 4)
    }

    // MARK: - Transcript body

    @ViewBuilder
    private func transcriptBody(_ segments: [TranscriptSegment]) -> some View {
        SectionText("Transcript")
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(seg.speaker)
                        .font(.callout.bold())
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 92, alignment: .leading)
                    Text(seg.text)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - State bodies

    private var failedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This meeting's summary couldn't be generated.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            if let err = live?.failureReason {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(live?.transcript.isEmpty == false
                 ? "The transcript is saved. Retry summary uses your current summary backend; Transcribe again also reruns speech recognition."
                 : "Retry uses the current transcription and summary backends.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var inFlightBody: some View {
        HStack(spacing: 10) {
            ProgressView()
            VStack(alignment: .leading, spacing: 6) {
                Text(live?.status == .recording
                 ? "Recording — stop the meeting to generate a summary."
                 : (vm.progressByMeeting[meeting.id]?.stage.rawValue.capitalized ?? "Working on it") + "…")
                .font(.callout)
                .foregroundStyle(.secondary)
                if let progress = vm.progressByMeeting[meeting.id], progress.stage == .diarizing, progress.fraction > 0 {
                    ProgressView(value: progress.fraction)
                    Text("Matching voices: \(Int(progress.fraction * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var emptyBody: some View {
        Text("No summary yet.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { actionButtons }
            VStack(alignment: .leading, spacing: 10) { actionButtons }
        }
    }

    @ViewBuilder private var actionButtons: some View {
            if live?.status == .processing {
                Button("Cancel processing") { vm.cancelProcessing(id: meeting.id) }
            }
            if live?.status == .recording {
                Button("Stop recording") { vm.stop() }.disabled(vm.isStarting)
            }
            if live?.status == .failed {
                Button {
                    retrying = true
                    Task { await vm.retry(id: meeting.id); retrying = false }
                } label: {
                    Label(live?.transcript.isEmpty == false ? "Retry summary" : "Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(retrying)
            }
            if (live?.status == .failed || live?.status == .summarized), live?.audioFileURLs.isEmpty == false {
                Button("Transcribe again") {
                    retrying = true
                    Task { await vm.retry(id: meeting.id, reuseTranscript: false); retrying = false }
                }.disabled(retrying)
            }
            if let s = live?.summary, !s.overall.isEmpty {
                Button {
                    copy(text: live?.summaryText() ?? "", label: "Summary")
                } label: {
                    Label(copied == "Summary" ? "Copied" : "Copy summary",
                          systemImage: "doc.on.doc")
                }
            }
            if let t = live?.transcript, !t.isEmpty {
                Button {
                    copy(text: live?.transcriptText() ?? "", label: "Transcript")
                } label: {
                    Label(copied == "Transcript" ? "Copied" : "Copy transcript",
                          systemImage: "doc.on.doc")
                }
            }
            if let url = live?.audioFileURLs.values.first {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                    .help("Show retained audio in Finder")
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(live?.status == .recording || live?.status == .processing)
    }

    private func copy(text: String, label: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copied = label
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = nil }
    }

    // MARK: - Formatting

    private var dateString: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: live?.startedAt ?? meeting.startedAt)
    }

    private var durationString: String {
        let secs = Int((live?.duration ?? meeting.duration).rounded())
        let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
