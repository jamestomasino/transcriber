import SwiftUI

#if canImport(TranscriberCore)
import TranscriberCore
#endif

/// The main window. Phase 3 adds the live audio meter and the permission /
/// capture-status card so the user can see input while recording and is told
/// exactly what to fix when a source fails. The full UI (detail view, menu bar,
/// onboarding, settings) lands in Phase 4.
struct ContentView: View {
    @ObservedObject var vm: TranscriberViewModel

    /// Local UI state (the meeting name to start with). This `@State` use is
    /// exactly the macro that the build's SDK-fallback exists for, so it is
    /// deliberately present to keep that path exercised.
    @State private var newTitle: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vm.isRecording {
                meter
                Divider()
            }
            if vm.hasCaptureProblem {
                statusCard
                Divider()
            }
            list
        }
        .frame(minWidth: 460, minHeight: 320)
        .onAppear { vm.startLevelMeter() }
        .onDisappear { vm.stopLevelMeter() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: vm.isRecording ? "record.circle.fill" : "waveform.circle.fill")
                .font(.title2)
                .foregroundStyle(vm.isRecording ? Color.red : Color.accentColor)
            Text("Transcriber")
                .font(.title2.bold())
            Spacer()
            if vm.isRecording {
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.variableColor, options: .repeating)
                    Text("Recording")
                        .foregroundStyle(.secondary)
                }
                Button {
                    vm.stop()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
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
                         active: vm.captureStatus[.mic] == nil)
                LevelBar(title: "System audio",
                         level: vm.level(.system),
                         icon: "speaker.wave.2.fill",
                         active: vm.captureStatus[.system] == nil)
            }
        }
        .padding(12)
    }

    // MARK: - Capture status

    /// A warning card, one line per failed source, naming the setting to flip.
    /// Shown whenever at least one requested source failed to start.
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Some audio isn't being captured", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
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
        Group {
            if vm.meetings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mic.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No meetings yet")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(vm.meetings) { m in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.title).font(.headline)
                            Text(m.status.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let s = m.summary {
                            Text(s.overall)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
            }
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
