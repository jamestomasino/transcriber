import Foundation
import UserNotifications

#if canImport(TranscriberCore)
import TranscriberCore
#endif

// MARK: - Notifications (App)
//
// The platform side of the notification seam. Core decides *what* to say
// (`MeetingNotificationPolicy`) and the view model calls the injected poster;
// this is the poster the app wires in. It owns `UNUserNotificationCenter` —
// the one framework that actually shows a banner — and nothing else, so Core
// stays free of UserNotifications.
//
// Two responsibilities:
//   1. `requestAuthorization()` — ask the user once, on launch, so the first
//      finished meeting can actually post (a banner is suppressed until
//      granted).
//   2. `post(_:)` — render a `MeetingNotification` into a
//      `UNMutableNotificationContent` and deliver it. Failures are swallowed:
//      a notification is a courtesy, never a reason to crash the pipeline.

public enum MeetingNotifications {
    private static let identifier = "com.transcriber.meeting"

    /// Ask for the permission to post banners. Idempotent and safe to call on
    /// every launch — macOS remembers the answer and does not re-prompt after
    /// the first decision.
    public static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            // The result is informational only; posting below checks the
            // effective authorization state regardless.
        }
    }

    /// Post a decided notification using the normal notification sound. The copy is
    /// verbatim from the pure decision. Never throws — a failed post is
    /// logged-and-forgotten.
    public static func post(_ note: MeetingNotification) {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        // Ordinary meeting updates respect normal notification and Focus settings.
        content.sound = .default
        content.categoryIdentifier = identifier

        let request = UNNotificationRequest(
            identifier: "\(identifier)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Transcriber: notification post failed: \(error.localizedDescription)")
            }
        }
    }
}
