import Foundation
import Dispatch
#if canImport(TranscriberCore)
import TranscriberCore
#endif

/// Observations stay in App. The scheduler/policy remains injectable and pure
/// with respect to platform services, files and recording hardware.
final class BackgroundResourceMonitor: @unchecked Sendable {
    static let shared = BackgroundResourceMonitor()
    private let lock = NSLock()
    private var memory: BackgroundConditions.Pressure = .normal
    private var pressure: DispatchSourceMemoryPressure?
    private var task: Task<Void, Never>?
    func start(scheduling: BackgroundProcessingScheduler) {
        guard task == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            self.lock.lock()
            self.memory = event.contains(.critical) ? .critical : (event.contains(.warning) ? .warning : .normal)
            self.lock.unlock()
        }
        pressure = source; source.resume()
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let conditions = self.conditions()
                await scheduling.updateConditions(conditions)
                await LocalInferenceQueue.shared.setCriticalPressure(conditions.memory == .critical || conditions.thermal == .critical)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    private func conditions() -> BackgroundConditions {
        lock.lock(); let memory = memory; lock.unlock()
        let thermal: BackgroundConditions.Pressure
        switch ProcessInfo.processInfo.thermalState {
        case .critical: thermal = .critical
        case .serious: thermal = .warning
        default: thermal = .normal
        }
        return BackgroundConditions(memory: memory, thermal: thermal, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
