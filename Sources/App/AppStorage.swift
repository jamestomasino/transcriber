import Foundation

#if canImport(TranscriberCore)
import TranscriberCore
#endif

/// Prepare the selected data folder before loading history or starting capture.
enum AppStorage {
    static func prepare(settings: AppSettings) throws {
        try FileManager.default.createDirectory(
            at: StorageDirectory.base(settings: settings),
            withIntermediateDirectories: true
        )
    }
}
