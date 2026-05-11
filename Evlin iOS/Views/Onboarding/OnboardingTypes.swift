import Foundation

enum OnboardingMode: String, Codable {
    case parent
    case child
}

/// Placeholder identifiers used **only** for demo onboarding shortcuts and DEBUG
/// "skip pairing" — never substitutes a real paired device once `/family/create` succeeds.
enum OnboardingDemoPlaceholders {
    /// Must stay in sync wherever we mount `BigKidRootView` without a server pairing.
    static let childDeviceUUIDString = "11111111-1111-4111-a111-111111111111"
    static let childDeviceUUID = UUID(uuidString: childDeviceUUIDString)!
}

/// Single-device testers (TestFlight + DEBUG): onboarding demo cards flip this `UserDefaults`
/// flag so the P/K float is shown in Release. Optional placeholder child UUID is only seeded
/// when this is set (DEBUG always opts in — engineers see the toggle in every Debug build).
enum EvlinDemoShortcuts {
    static let userDefaultsKey = "evlin.demoSingleDeviceShortcutsEnabled"

    static var allowsPlaceholderChildUUID: Bool {
        #if DEBUG
        true
        #else
        UserDefaults.standard.bool(forKey: userDefaultsKey)
        #endif
    }

    static func enable() {
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
    }

    /// Cleared on onboarding reset flows so App Store testers don’t keep the float after “real” rerun.
    static func clearFlag() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    static func seedPlaceholderChildUUIDIfMissing() {
        guard allowsPlaceholderChildUUID else { return }
        let key = "evlin.childDeviceID"
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        if raw.isEmpty || UUID(uuidString: raw) == nil {
            UserDefaults.standard.set(OnboardingDemoPlaceholders.childDeviceUUIDString, forKey: key)
        }
    }

    /// When `evlin.familyID` is still empty (demo skipped real pairing), hit the same
    /// `/family/create` + `/family/pair` sequence as `SpikeView` so Chat-queued locks
    /// have a real family + child on the server.
    static func scheduleBackendDemoPairingIfNeeded() {
        guard allowsPlaceholderChildUUID else { return }
        let fam = (UserDefaults.standard.string(forKey: "evlin.familyID") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard fam.isEmpty else { return }

        Task { @MainActor in
            await applyBackendDemoPairing()
        }
    }

    @MainActor
    private static func applyBackendDemoPairing() async {
        let client = APIClient()
        let base = client.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return }
        do {
            let r = try await DemoFamilyBootstrap.pairSingleDeviceOnBackend(baseURL: base)
            UserDefaults.standard.set(r.familyID.uuidString, forKey: "evlin.familyID")
            UserDefaults.standard.set(r.childDeviceID.uuidString, forKey: "evlin.childDeviceID")
            UserDefaults.standard.set(r.parentDeviceID.uuidString, forKey: "evlin.parentDeviceID")
            UserDefaults.standard.set(r.protectionMode, forKey: "evlin.protectionMode")
            NotificationCenter.default.post(name: .bigKidStateInvalidated, object: nil)
        } catch {
            #if DEBUG
            print("[EvlinDemoShortcuts] backend demo pairing failed: \(error)")
            #endif
        }
    }
}
