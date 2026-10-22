import Foundation
import Combine

/// View model for the app.
///
/// The `TrackerViewModel` analog from the base repo: it is the single shared
/// object the window and (later) the menu bar observe. It drives the pure
/// `MeetingEngine` and republishes its state, and it is where the I/O side
/// effects (recording, transcription, summary, retention) get wired in later
/// phases via injected closures.
///
/// Lives in Core (Combine, not SwiftUI/AppKit) so it is testable headless —
/// the same seam the base repo uses.
@MainActor
public final class TranscriberViewModel: ObservableObject {
    @Published public private(set) var meetings: [Meeting] = []
    @Published public var activeTitle: String?
    @Published public var toast: String?

    private let engine: MeetingEngine
    private let clock: Clock

    /// Injected in later phases (Phase 2+). Kept as closures so Core stays
    /// free of AVFoundation/Speech/network imports.
    public var beginRecording: ((UUID) -> Void)?
    public var endRecording: ((UUID) -> Void)?
    public var process: ((UUID) -> Void)?

    public init(engine: MeetingEngine = MeetingEngine(), clock: Clock = SystemClock()) {
        self.engine = engine
        self.clock = clock
        publish()
    }

    // MARK: - Actions

    public func start(title: String? = nil) {
        let m = engine.start(title: title)
        beginRecording?(m.id)
        activeTitle = m.title
        publish()
        show("Recording \(m.title)")
    }

    public func stop() {
        guard let a = engine.active else { return }
        engine.stop(id: a.id)
        endRecording?(a.id)
        process?(a.id)
        activeTitle = nil
        publish()
        show("Stopping… summarizing")
    }

    public func delete(id: UUID) {
        engine.delete(id: id)
        publish()
    }

    // MARK: - Internals

    private func publish() {
        meetings = engine.recent
    }

    private var toastTask: Task<Void, Never>?
    private func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
