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

    /// The meeting as it currently stands (it can change while we're looking
    /// at it — e.g. retry flips failed → summarized). Re-read from the VM so
    /// the view tracks live state rather than a stale copy.
    private var live: Meeting? { vm.meetings.first(where: { $0.id == meeting.id }) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                if let s = live?.summary {
                    summaryBody(s)
                } else if live?.status == .failed {
                    failedBody
                } else if live?.status == .processing || live?.status == .recording {
                    inFlightBody
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
        .frame(minWidth: 380, maxWidth: .infinity)
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
                    Label("\(n) speaker\(n == 1 ? "" : "s")", systemImage: "person.2")
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
            if let err = vm.processingError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("You can retry it below (it uses the current backend and key).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var inFlightBody: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(live?.status == .recording
                 ? "Recording — stop the meeting to generate a summary."
                 : "Working on it…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyBody: some View {
        Text("No summary yet.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 10) {
            if live?.status == .failed {
                Button {
                    retrying = true
                    Task { await vm.retry(id: meeting.id); retrying = false }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(retrying)
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
            Spacer()
            Button(role: .destructive) {
                vm.delete(id: meeting.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
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
