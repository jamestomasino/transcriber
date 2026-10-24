import SwiftUI
import AppKit

#if canImport(TranscriberCore)
import TranscriberCore
#endif

/// The main window. Phase 3 adds the live audio meter and the permission /
/// capture-status card so the user can see input while recording and is told
/// exactly what to fix when a source fails. Phase 6 adds a detail pane (full
/// structured summary + retained transcript + retry / copy / delete) so the
/// user can actually read the artifact the app produces.
struct ContentView: View {
    @ObservedObject var vm: TranscriberViewModel

    /// Local UI state (the meeting name to start with). This `@State` use is
    /// exactly the macro that the build's SDK-fallback exists for, so it is
    /// deliberately present to keep that path exercised.
    @State private var newTitle: String = ""
    /// The meeting currently selected in the list, shown in the detail pane.
    @State private var selection: Meeting.ID?
    @State private var query = ""
    @State private var showSetup = false

    var body: some View {
        VStack(spacing: 0) {
            header
            LocalModelDownloadBanner()
            Divider()
            if vm.isRecording { meter; Divider() }
            if vm.hasCaptureProblem || vm.processingError != nil { statusCard; Divider() }
            HSplitView {
                list.frame(minWidth: 220, idealWidth: 280, maxWidth: 340)
                Group {
                    if let id = selection, let m = vm.meetings.first(where: { $0.id == id }) {
                        MeetingDetailView(vm: vm, meeting: m)
                    } else {
                        detailPlaceholder
                    }
                }
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 800, minHeight: 440)
        .overlay(alignment: .bottom) {
            if let message = vm.toastMessage {
                Text(message).font(.callout).padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding()
                    .accessibilityLabel(message)
            }
        }
        .sheet(isPresented: $showSetup) {
            VStack { OnboardingView(vm: vm); Button("Done") { showSetup = false }.padding() }.frame(width: 560)
        }
        .onAppear { selection = selection ?? vm.meetings.first?.id; vm.startLevelMeter() }
        .onChange(of: vm.meetings.map(\.id)) { _, ids in
            if selection.map({ !ids.contains($0) }) ?? true { selection = ids.first }
        }
        .onDisappear { vm.stopLevelMeter() }
    }

    @ViewBuilder
    private var detailPlaceholder: some View {
        if vm.meetings.isEmpty {
            ScrollView { OnboardingView(vm: vm).frame(maxWidth: .infinity) }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Select a meeting to read its summary")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppIconView()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Spacer()
            Button { showSetup = true } label: { Image(systemName: "questionmark.circle") }
                .help("Setup and permissions")
            if vm.isRecording || vm.isStopping {
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.variableColor, options: .repeating)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(vm.isStopping ? "Finishing recording…" : vm.isStarting ? "Starting…" : elapsed(at: context.date))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    vm.stop()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isStarting || vm.isStopping)
            } else {
                TextField("Meeting name (optional)", text: $newTitle)
                    .frame(maxWidth: 220)
                    .textFieldStyle(.roundedBorder)
                Button {
                    vm.start(title: newTitle.isEmpty ? nil : newTitle)
                    newTitle = ""
                } label: {
                    Label("Start", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.settings.requestedSources.isEmpty || vm.isStarting || vm.isStopping)
            }
        }
        .padding(12)
    }

    // MARK: - Live meter

    /// Two live level bars (mic + system), shown only while recording. Levels
    /// are pushed by the view model's meter task every ~100 ms.
    private var meter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                LevelBar(title: "Microphone",
                         level: vm.level(.mic),
                         icon: "mic.fill",
                         active: vm.settings.captureMic && vm.captureStatus[.mic] == nil)
                LevelBar(title: "System audio",
                         level: vm.level(.system),
                         icon: "speaker.wave.2.fill",
                         active: vm.settings.captureSystem && vm.captureStatus[.system] == nil)
            }
        }
        .padding(12)
    }

    // MARK: - Capture status

    /// A warning card, one line per failed source, naming the setting to flip.
    /// Shown whenever at least one requested source failed to start.
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(vm.hasCaptureProblem ? "Some audio isn't being captured" : "Meeting needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            if let error = vm.processingError { Text(error).font(.callout).foregroundStyle(.secondary) }
            Button("Setup and permissions") { showSetup = true }
            ForEach(vm.captureStatusMessages, id: \.self) { msg in
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search meetings", text: $query).textFieldStyle(.roundedBorder)
            }
            .padding(10)
            Divider()
            if vm.meetings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mic.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No meetings yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(vm.search(query)) { m in
                        HStack {
                            Image(systemName: statusIcon(m.status))
                                .foregroundStyle(statusColor(m.status))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(m.title).font(.headline)
                                Text(m.startedAt, style: .date)
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(statusLabel(m.status))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let s = m.summary, !s.overall.isEmpty {
                                Text(s.overall)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(m.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func elapsed(at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(vm.activeMeeting?.startedAt ?? now)))
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private func statusIcon(_ s: MeetingStatus) -> String {
        switch s {
        case .recording:  return "record.circle.fill"
        case .processing: return "hourglass"
        case .summarized: return "checkmark.circle.fill"
        case .failed:     return "xmark.circle.fill"
        }
    }

    private func statusColor(_ s: MeetingStatus) -> Color {
        switch s {
        case .recording:  return .orange
        case .processing: return .blue
        case .summarized: return .green
        case .failed:     return .red
        }
    }

    private func statusLabel(_ s: MeetingStatus) -> String {
        switch s {
        case .recording:  return "Recording"
        case .processing: return "Processing…"
        case .summarized: return "Summarized"
        case .failed:     return "Failed — select to retry"
        }
    }
}

// MARK: - Level bar

/// A single labelled level meter. `level` is 0...1; the filled portion scales
/// with it. When `active` is false (that source failed to start) the bar shows
/// a muted "off" state instead of a live level.
private struct LevelBar: View {
    let title: String
    let level: Float
    let icon: String
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                    Capsule()
                        .fill(active ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: max(0, min(1, Double(level))) * geo.size.width)
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - App icon

/// The app's own icon, loaded from the bundle so it always matches the
/// Dock / Finder icon the user sees. Falls back to an SF Symbol if the
/// icon can't be resolved (e.g. running from a bare binary in tests).
private struct AppIconView: View {
    var body: some View {
        if let image = NSApp.applicationIconImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "waveform.circle.fill")
                .resizable()
                .foregroundStyle(Color.accentColor)
        }
    }
}
