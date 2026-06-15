import Combine
import Foundation
import UserNotifications

/// Kid-side notification-permission monitor (notif spec §1.4 / Phase 5).
///
/// On appear + every foreground it reads `getNotificationSettings()` and:
///   1. publishes `notificationsOff` so the kid root can show the
///      "turn notifications back on" nudge, and
///   2. reports the snapshot to `POST /child/notification-settings` so the
///      backend can route around the off device and alert the parent (#22).
///
/// "Off" means the device can't receive a visible alert — `denied`, or alerts
/// explicitly disabled. Provisional/quiet delivery still counts as on (a silent
/// wake can land), matching the backend's `notifications_effectively_off`.
@MainActor
final class NotificationStatusMonitor: ObservableObject {
    @Published private(set) var notificationsOff = false

    private let childDeviceID: UUID
    private let baseURL: String

    init(childDeviceID: UUID, baseURL: String) {
        self.childDeviceID = childDeviceID
        self.baseURL = baseURL
    }

    func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self else { return }
            let off = settings.authorizationStatus == .denied
                || settings.alertSetting == .disabled
            Task { @MainActor in
                self.notificationsOff = off
                await self.report(settings)
            }
        }
    }

    private func report(_ settings: UNNotificationSettings) async {
        guard !baseURL.isEmpty,
              let url = URL(string: "\(baseURL)/child/notification-settings") else { return }

        func name(_ s: UNNotificationSetting) -> String {
            switch s {
            case .enabled: return "enabled"
            case .disabled: return "disabled"
            default: return "not_supported"
            }
        }
        let auth: String
        switch settings.authorizationStatus {
        case .authorized: auth = "authorized"
        case .denied: auth = "denied"
        case .provisional: auth = "provisional"
        case .ephemeral: auth = "ephemeral"
        default: auth = "not_determined"
        }
        let body: [String: Any] = [
            "device_id": childDeviceID.uuidString,
            "authorization_status": auth,
            "alert_setting": name(settings.alertSetting),
            "sound_setting": name(settings.soundSetting),
            "badge_setting": name(settings.badgeSetting),
            "time_sensitive_setting": name(settings.timeSensitiveSetting),
            "scheduled_delivery_setting": name(settings.scheduledDeliverySetting),
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            #if DEBUG
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                print("NotificationStatusMonitor report failed: HTTP \(http.statusCode)")
            }
            #endif
        } catch {
            #if DEBUG
            print("NotificationStatusMonitor report failed: \(error.localizedDescription)")
            #endif
        }
    }
}
