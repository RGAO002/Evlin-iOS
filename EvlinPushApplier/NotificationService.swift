import UserNotifications
import ManagedSettings
import Foundation

/// SPIKE-ONLY Notification Service Extension (target: EvlinPushApplier).
///
/// Sole purpose: prove whether an NSE process — holding the Family Controls
/// entitlement — can apply a ManagedSettings block while the main Evlin app is
/// FORCE-QUIT. iOS spins this extension up for any alert push carrying
/// `mutable-content: 1`, even when the host app is user-terminated. On delivery
/// it blocks Safari via an ISOLATED named store (so it never touches production
/// lock state and is trivially cleared from the debug menu), records a
/// timestamped result into the App Group, then shows the notification.
///
/// Throwaway: delete this target once the spike concludes.
class NotificationService: UNNotificationServiceExtension {
    // Isolated named store — independent of the production default store, so the
    // spike can never corrupt real locks and is cleared on its own.
    private let store = ManagedSettingsStore(named: .init("evlin.nsespike"))
    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let ts = ISO8601DateFormatter().string(from: Date())
        // seq is stamped by the test sender so hits/misses are unambiguous;
        // action lets the sender toggle block vs clear (so Safari can be
        // restored over the air); lowPower tags the device condition.
        let evlin = request.content.userInfo["evlin"] as? [String: Any]
        let seq = (evlin?["seq"]).map { "\($0)" } ?? "?"
        let action = (evlin?["action"] as? String) ?? "block"
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

        // THE DECISIVE TEST: write ManagedSettings from inside the NSE process.
        // Real lock commands are both block AND unblock, so the spike exercises
        // both: action=clear/unblock restores, anything else blocks Safari.
        if action == "clear" || action == "unblock" {
            store.clearAllSettings()
        } else {
            store.application.blockedApplications = [
                Application(bundleIdentifier: "com.apple.mobilesafari")
            ]
        }
        appendLog("fired \(ts) seq=\(seq) action=\(action) lowPower=\(lowPower)")

        // Show the (possibly modified) content. The visible alert is the price
        // of admission that let iOS run this code under force-quit.
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        if content.title.isEmpty { content.title = "Evlin" }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        // Reached only if iOS pre-empts us before contentHandler. The block
        // write above is synchronous, so by here it has already been attempted.
        appendLog("serviceExtensionTimeWillExpire")
    }

    private func appendLog(_ line: String) {
        // Keys MUST match CommandDeliveryDiagnostics.keyNSELog / keyNSECount.
        let logKey = "evlin.spike.nseLog"
        let countKey = "evlin.spike.nseCount"
        var log = defaults?.stringArray(forKey: logKey) ?? []
        log.append(line)
        if log.count > 30 { log.removeFirst(log.count - 30) }
        defaults?.set(log, forKey: logKey)
        defaults?.set((defaults?.integer(forKey: countKey) ?? 0) + 1, forKey: countKey)
    }
}
