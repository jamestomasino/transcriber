import SwiftUI

#if canImport(TranscriberCore)
import TranscriberCore
#endif

/// The main window. Phase 0 is a deliberately thin shell: it proves the
/// build + macro path works and renders the engine's state. The real UI
/// (list, detail, menu bar, onboarding, settings) lands in Phase 4.
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
            list
        }
        .frame(minWidth: 460, minHeight: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Transcriber")
                .font(.title2.bold())
            Spacer()
            if vm.isRecording {
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
