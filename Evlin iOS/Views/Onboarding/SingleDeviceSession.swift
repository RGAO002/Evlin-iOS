import Foundation

/// Single Device Mode (demo purpose only): testers with one phone run the full real
/// onboarding, then use the P/K float to switch this device between parent and kid.
/// Thin wrapper over the EXISTING `EvlinDemoShortcuts` flag — adds the interleaved
/// onboarding stage + a per-run demo identity so repeat runs don't trip /pair 409.
///
/// SAFETY INVARIANT: this only gates the float + onboarding orchestration. It is never
/// read by any command / lock / notification path. A normal parent or kid device never
/// calls `enable()`, so `isEnabled` stays false and no float ever appears.
@MainActor
final class SingleDeviceSession {
    static let shared = SingleDeviceSession()
    private let d = UserDefaults.standard

    /// THE single-device flag = the EXISTING `EvlinDemoShortcuts` key, read as a PLAIN bool.
    /// Deliberately does NOT read `EvlinDemoShortcuts.allowsPlaceholderChildUUID` — that is
    /// DEBUG-always-true legacy demo-shortcut semantics (`OnboardingTypes.swift`) and reading it
    /// would make every DEBUG parent/kid build look like single-device and show the float.
    /// `enable()` must be called explicitly (the new "Single Device Mode" onboarding entry).
    var isEnabled: Bool { d.bool(forKey: EvlinDemoShortcuts.userDefaultsKey) }

    /// The float shows only when the flag is set AND all three real ids exist.
    var isActive: Bool {
        isEnabled && !id("evlin.childDeviceID").isEmpty
            && !id("evlin.parentDeviceID").isEmpty && !id("evlin.familyID").isEmpty
    }

    func enable() {
        d.set(true, forKey: EvlinDemoShortcuts.userDefaultsKey)
        if demoEmailRaw.isEmpty { d.set(Self.mintDemoEmail(), forKey: kEmail) }
        if (d.string(forKey: kPass) ?? "").isEmpty { d.set(Self.mintDemoPassword(), forKey: kPass) }
        if (d.string(forKey: kInstall) ?? "").isEmpty { d.set(UUID().uuidString, forKey: kInstall) }
    }

    var demoEmail: String { demoEmailRaw }
    var demoPassword: String { d.string(forKey: kPass) ?? "" }  // ≥8 chars for POST /auth/email
    var clientInstallIDOverride: String { d.string(forKey: kInstall) ?? "" }

    /// Onboarding orchestration stage (drives the interleave in OnboardingCoordinator).
    enum Stage: String { case idle, kidCreate, parentPair, kidPermit, parentPayoff, done }
    var stage: Stage {
        get { Stage(rawValue: d.string(forKey: kStage) ?? "") ?? .idle }
        set { d.set(newValue.rawValue, forKey: kStage) }
    }

    /// Each demo run mints a FRESH email+password+install id so `/family/pair` never 409s on a
    /// reused account. `auth` is the coordinator's live `AuthService` — passing it clears the
    /// Keychain session (`signOutLocally` is an instance method). Tests pass `nil` to stay off
    /// the real Keychain.
    func resetForNewRun(auth: AuthService? = nil) {
        auth?.signOutLocally()
        for k in ["evlin.childDeviceID", "evlin.parentDeviceID", "evlin.familyID",
                  "evlin.protectionMode", kEmail, kPass, kInstall, kStage] {
            d.removeObject(forKey: k)
        }
        EvlinDemoShortcuts.clearFlag()
        d.set("", forKey: "appMode")
    }

    private let kEmail = "evlin.singleDevice.demoEmail"
    private let kPass = "evlin.singleDevice.demoPassword"
    private let kInstall = "evlin.singleDevice.clientInstallIDOverride"
    private let kStage = "evlin.singleDevice.stage"
    private var demoEmailRaw: String { d.string(forKey: kEmail) ?? "" }
    private func id(_ k: String) -> String { (d.string(forKey: k) ?? "").trimmingCharacters(in: .whitespaces) }
    private static func mintDemoEmail() -> String { "demo+\(UUID().uuidString.prefix(8).lowercased())@evlin.test" }
    private static func mintDemoPassword() -> String { "Demo-" + UUID().uuidString.prefix(12) } // ≥8 for /auth/email
}
