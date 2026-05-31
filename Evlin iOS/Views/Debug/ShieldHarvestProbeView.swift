// Evlin iOS/Evlin iOS/Views/Debug/ShieldHarvestProbeView.swift
//
// E1 probe — ShieldConfiguration "harvest" channel.
//
// Hypothesis (from the 2026-05-29 architecture memo): a ShieldConfiguration
// extension is the ONE place that BOTH (a) resolves an app's
// localizedDisplayName / bundleIdentifier in-process (like DAR, unlike the main
// app where they're nil) AND (b) can write to the App Group (like DAM, unlike
// DAR whose sandbox blocks export). If true, it's a token→name/bundleID export
// channel that nothing else provides.
//
// Test flow:
//   1. Apply a shield to the current Managed Apps selection (so opening one of
//      those apps triggers the system to render OUR ShieldConfiguration).
//   2. On the device, open a shielded app → the shield screen appears → iOS
//      calls EvlinShieldConfigDataSource.configuration(shielding:) → that
//      extension writes {displayName, bundleID, token} to the App Group.
//   3. Come back here, tap "Read harvest", and see whether the name/bundleID
//      crossed into the main app via any of: UserDefaults / file / keychain.
//
// REQUIRES the EvlinShieldConfig extension target to exist (see
// EvlinShieldConfig/ source). Until that target is built+embedded, "Read
// harvest" will always be empty (nothing is writing the key).
import SwiftUI
import FamilyControls
import ManagedSettings
import Security

struct ShieldHarvestProbeView: View {
    @EnvironmentObject private var screenTimeManager: ScreenTimeManager

    private let store = ManagedSettingsStore()
    private let appGroup = "group.com.evlin.ios"
    private let harvestKey = "evlin.shieldconfig.harvest"
    private let keychainGroup = "D9FM36P37F.com.evlin.darbridge"

    @State private var status: String = ""
    @State private var harvestResult: String = ""

    private var appTokens: Set<ApplicationToken> {
        screenTimeManager.selectedApps.applicationTokens
    }

    var body: some View {
        List {
            Section {
                Text(
                    """
                    E1 probe: does a ShieldConfiguration extension harvest an \
                    app's name/bundleID and export it via App Group? Apply a \
                    shield, open a shielded app on THIS device so the shield \
                    screen renders, then come back and Read harvest.

                    If "Read harvest" stays empty, either the EvlinShieldConfig \
                    extension target isn't built/embedded yet, or its sandbox \
                    blocks the write (DAR-style).
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                LabeledContent("Selected app tokens", value: "\(appTokens.count)")
                LabeledContent("Screen Time auth") {
                    Text(screenTimeManager.isAuthorized ? "approved" : "not approved")
                        .foregroundStyle(screenTimeManager.isAuthorized ? .green : .red)
                }
            }

            Section("Step 1 — apply shield (triggers ShieldConfiguration)") {
                Button {
                    applyShieldToSelection()
                } label: {
                    Label("Shield current selection", systemImage: "lock.fill")
                }
                .disabled(appTokens.isEmpty)

                Button {
                    applyShieldAllCategories()
                } label: {
                    Label("Shield ALL categories (broad)", systemImage: "lock.shield.fill")
                }

                Button(role: .destructive) {
                    clearShield()
                } label: {
                    Label("Clear shield", systemImage: "lock.open.fill")
                }

                if !status.isEmpty {
                    Text(status)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Section("Step 2 — open a shielded app on this device") {
                Text("Go to the Home Screen and tap one of the shielded apps. The Evlin shield screen should appear — that's the system invoking our ShieldConfiguration extension. Then return here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Step 3 — read what the extension harvested") {
                Button {
                    harvestResult = readHarvest()
                } label: {
                    Label("Read harvest (App Group / file / keychain)", systemImage: "tray.and.arrow.down.fill")
                }

                if !harvestResult.isEmpty {
                    Text(harvestResult)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(harvestResult.contains("✅") ? .green : .orange)
                }
            }
        }
        .navigationTitle("ShieldConfig harvest (E1)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { screenTimeManager.refreshAuthorizationStatus() }
    }

    private func applyShieldToSelection() {
        store.shield.applications = appTokens.isEmpty ? nil : appTokens
        status = "Shielded \(appTokens.count) app token(s). Now open one of them."
    }

    private func applyShieldAllCategories() {
        store.shield.applicationCategories = .all()
        status = "Shielded ALL categories. Open any non-system app to trigger the shield."
    }

    private func clearShield() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        status = "Shield cleared."
    }

    /// Read every channel the extension might have written to.
    private func readHarvest() -> String {
        var lines: [String] = []

        // (1) App Group UserDefaults
        if let defaults = UserDefaults(suiteName: appGroup) {
            if let s = defaults.string(forKey: harvestKey), !s.isEmpty {
                lines.append("✅ UserDefaults: \(s)")
            } else if let data = defaults.data(forKey: harvestKey),
                      let s = String(data: data, encoding: .utf8), !s.isEmpty {
                lines.append("✅ UserDefaults(data): \(s)")
            } else {
                lines.append("✗ UserDefaults[\(harvestKey)] empty")
            }
            if let diag = defaults.string(forKey: "evlin.shieldconfig.diag") {
                lines.append("  diag: \(diag)")
            }
        } else {
            lines.append("✗ UserDefaults(suiteName:) nil")
        }

        // (2) App Group file
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            let url = container.appendingPathComponent("shieldconfig-harvest.json")
            if let data = try? Data(contentsOf: url),
               let s = String(data: data, encoding: .utf8), !s.isEmpty {
                lines.append("✅ file: \(s)")
            } else {
                lines.append("✗ file shieldconfig-harvest.json empty/absent")
            }
        }

        // (3) Keychain shared group
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "evlin.shieldconfig.harvest",
            kSecAttrAccessGroup as String: keychainGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecSuccess, let d = out as? Data,
           let s = String(data: d, encoding: .utf8) {
            lines.append("✅ keychain: \(s)")
        } else {
            lines.append("✗ keychain SecItemCopyMatching=\(st)")
        }

        return lines.joined(separator: "\n")
    }
}
