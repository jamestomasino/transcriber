import Foundation

/// Numeric, bounded diagnostics. Never contains meeting text, paths or prompts.
public struct ProcessingMeasurement: Codable, Sendable {
    public let stage: String
    public let seconds: Double
    public let inputTokens: Int?
    public let outputTokens: Int?
}

public actor ProcessingMeasurements {
    public static let shared = ProcessingMeasurements()
    private var samples: [ProcessingMeasurement] = []
    public init() {}
    public func record(_ stage: String, seconds: Double, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        samples.append(ProcessingMeasurement(stage: stage, seconds: max(0, seconds), inputTokens: inputTokens, outputTokens: outputTokens))
        if samples.count > 256 { samples.removeFirst(samples.count - 256) }
    }
    public func snapshot() -> [ProcessingMeasurement] { samples }
    public func reset() { samples = [] }
    public static func measure<T>(_ stage: String, operation: () async throws -> T) async rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let value = try await operation()
            await shared.record(stage, seconds: ProcessInfo.processInfo.systemUptime - start)
            return value
        } catch {
            await shared.record(stage + ".interrupted", seconds: ProcessInfo.processInfo.systemUptime - start)
            throw error
        }
    }
}

public struct BackgroundConditions: Equatable, Sendable {
    public enum Pressure: Int, Sendable { case normal, warning, critical }
    public var memory: Pressure
    public var thermal: Pressure
    public var lowPower: Bool
    public init(memory: Pressure = .normal, thermal: Pressure = .normal, lowPower: Bool = false) {
        self.memory = memory; self.thermal = thermal; self.lowPower = lowPower
    }
}

public enum ProcessingWorkState: Equatable, Sendable {
    case queued(position: Int)
    case running
    case deferred(reason: String)
    public var description: String {
        switch self {
        case .queued(let position): return "Queued · position \(position)"
        case .running: return "Processing"
        case .deferred(let reason): return "Waiting — \(reason)"
        }
    }
}

public struct ProcessingResourceInterruption: LocalizedError, Sendable {
    public var errorDescription: String? { "Processing stopped to protect other applications during critical resource pressure. Audio was kept. Resume when the Mac has recovered." }
    public init() {}
}

/// FIFO admission for an entire meeting, including preparation. The native
/// inference guard remains separate: never recursively acquire that guard.
/// Whole-meeting admission prevents model/preparation churn across a backlog.
public actor BackgroundProcessingScheduler {
    private struct Waiting {
        let id: UUID
        let report: @Sendable (ProcessingWorkState) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiting: [Waiting] = []
    private var active: UUID?
    private var activeReport: (@Sendable (ProcessingWorkState) -> Void)?
    private var activeCancel: (@Sendable () -> Void)?
    private var activeBoundary: CheckedContinuation<Void, Error>?
    private var interrupted = false
    private var recording = false
    private var conditions = BackgroundConditions()
    private var recoverAfter: TimeInterval = 0
    private var lowPowerDelayUntil: TimeInterval?
    private let now: @Sendable () -> TimeInterval
    private let recoverySeconds: TimeInterval
    public init(recoverySeconds: TimeInterval = 15, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.recoverySeconds = recoverySeconds; self.now = now
    }
    public func setRecording(_ recording: Bool) { self.recording = recording; drain() }
    public func updateConditions(_ next: BackgroundConditions) {
        if next.memory != .normal || next.thermal != .normal { recoverAfter = now() + recoverySeconds }
        if next.lowPower && !conditions.lowPower { lowPowerDelayUntil = now() + 30 }
        if !next.lowPower { lowPowerDelayUntil = nil }
        conditions = next
        if next.memory == .critical || next.thermal == .critical {
            interrupted = active != nil
            activeCancel?()
        }
        drain()
    }
    private var reason: String? {
        if recording { return "a recording is in progress" }
        if conditions.memory != .normal { return "the Mac needs memory for other applications" }
        if conditions.thermal != .normal { return "the Mac is cooling down" }
        if now() < recoverAfter { return "resources are recovering" }
        if let until = lowPowerDelayUntil, now() < until { return "Low Power Mode is deferring background work briefly" }
        return nil
    }
    public func checkpoint() async throws {
        try Task.checkCancellation()
        guard active != nil else { return }
        guard let reason else { return }
        activeReport?(.deferred(reason: reason))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { activeBoundary = continuation }
            }
        } onCancel: { Task { await self.cancelBoundary() } }
    }
    private func cancelBoundary() {
        activeBoundary?.resume(throwing: CancellationError()); activeBoundary = nil
    }
    public func run<T: Sendable>(id: UUID, report: @escaping @Sendable (ProcessingWorkState) -> Void,
                                 operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let start = now()
        try await acquire(id: id, report: report)
        await ProcessingMeasurements.shared.record("queue.wait", seconds: now() - start)
        defer { release() }
        try Task.checkCancellation()
        if interrupted { throw ProcessingResourceInterruption() }
        let task = Task(priority: .utility) { try await operation() }
        activeCancel = { task.cancel() }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            if interrupted { throw ProcessingResourceInterruption() }
            try Task.checkCancellation()
            return result
        } catch {
            if interrupted { throw ProcessingResourceInterruption() }
            throw error
        }
    }
    private func acquire(id: UUID, report: @escaping @Sendable (ProcessingWorkState) -> Void) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiting.append(Waiting(id: id, report: report, continuation: continuation)); drain()
            }
        } onCancel: { Task { await self.cancelWaiting(id) } }
    }
    private func cancelWaiting(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        }
        drain()
    }
    private func release() {
        cancelBoundary(); active = nil; activeReport = nil; activeCancel = nil; interrupted = false; drain()
    }
    private func drain() {
        if let reason {
            for job in waiting { job.report(.deferred(reason: reason)) }
            if activeBoundary != nil { activeReport?(.deferred(reason: reason)) }
            return
        }
        if activeBoundary != nil {
            activeBoundary?.resume(); activeBoundary = nil; activeReport?(.running)
        }
        if active == nil, !waiting.isEmpty {
            let next = waiting.removeFirst(); active = next.id; activeReport = next.report
            next.report(.running); next.continuation.resume()
        }
        for (index, job) in waiting.enumerated() { job.report(.queued(position: index + 1)) }
    }
}
