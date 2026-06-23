// Evlin iOS/Evlin iOS/Views/Debug/DARNumberExportProbeView.swift
//
// DEBUG-only spike: can a plain Double (today's whole-device total
// screen-time seconds) cross the DeviceActivityReport sandbox via the App
// Group, and be read back here in the main app?
//
// Why this matters: writing the opaque `ApplicationToken` out of DAR FAILS on
// iOS 26 (PropertyListEncoder broke on FamilyControls tokens — see
// LocalAliasStore.hydrateFromReportDetailed). Strings and Date DO cross, so a
// Double should too — but "should" isn't "proven on device". This confirms it.
//
// Flow:
//   1. "Run report" renders the EvlinDeviceActivityReport `evlin.totalUsage`
//      scene with an all-activity filter (no app/category restriction = the
//      whole device, INCLUDING apps the parent never selected). The extension
//      sums every category's duration and writes the Double to the App Group.
//   2. "Read number" reads it back here. A value + fresh heartbeat = the number
//      crossed the sandbox, so the precise total-screen-time path is viable.
//
// DAR reports the device it RUNS ON: on a parent phone you see the parent's own
// usage; on a child phone, the child's. Either proves the channel works.
#if DEBUG
import DeviceActivity
import Security
import SwiftUI

private extension DeviceActivityReport.Context {
    static let evlinTotalUsage = Self("evlin.totalUsage")
}

struct DARNumberExportProbeView: View {
    @EnvironmentObject private var screenTimeManager: ScreenTimeManager
    @State private var refreshID = UUID()
    @State private var readback: String = ""
    @State private var crossed = false
    @State private var authBusy = false

    // Today only, all activity (no app/category restriction) = whole device.
    private var filter: DeviceActivityFilter {
        let start = Calendar.current.startOfDay(for: Date())
        return DeviceActivityFilter(
            segment: .daily(during: DateInterval(start: start, end: Date())),
            devices: .all
        )
    }

    var body: some View {
        List {
            Section {
                Text(
                    """
                    Tests whether a plain number — today's whole-device screen-time seconds — can be written OUT of the DeviceActivityReport sandbox into the App Group, then read back here in the main app.

                    DAR measures THIS device: on a parent phone you'll see the parent's own usage; on a child phone, the child's. Either way it proves the channel.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("0 · Screen Time authorization (required)") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(screenTimeManager.isAuthorized ? "approved" : "not approved")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(screenTimeManager.isAuthorized ? .green : .red)
                }
                Button {
                    authBusy = true
                    Task {
                        await screenTimeManager.requestScreenTimeAuthorization()
                        await MainActor.run {
                            screenTimeManager.refreshAuthorizationStatus()
                            authBusy = false
                        }
                    }
                } label: {
                    Label(
                        authBusy ? "Requesting…" : "Request Screen Time authorization",
                        systemImage: "checkmark.shield"
                    )
                }
                .disabled(authBusy || screenTimeManager.isAuthorized)
                if let err = screenTimeManager.errorMessage, !err.isEmpty {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
                Text("DAR renders only on a Screen-Time-authorized device — without this the report below stays blank. On a parent phone this authorizes the parent's OWN device (.individual, picks up evlin.protectionMode); a child device is already authorized via onboarding.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("1 · Run the report extension") {
                DeviceActivityReport(.evlinTotalUsage, filter: filter)
                    .id(refreshID)
                    .frame(minHeight: 240)
                Button {
                    refreshID = UUID()
                    readback = ""
                } label: {
                    Label("Run / refresh report", systemImage: "arrow.clockwise")
                }
            }

            Section("2 · Read it back (main app side)") {
                Button {
                    readback = readExportedNumber()
                } label: {
                    Label("Read number back (App Group + Keychain)", systemImage: "tray.and.arrow.down")
                }
                if !readback.isEmpty {
                    Text(readback)
                        .font(.caption.monospaced())
                        .foregroundStyle(crossed ? .green : .orange)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("DAR number export")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { screenTimeManager.refreshAuthorizationStatus() }
    }

    /// Read the exported Double from BOTH App Group channels (UserDefaults +
    /// file). If either carries a value the number crossed the DAR sandbox.
    private func readExportedNumber() -> String {
        guard let defaults = UserDefaults(suiteName: "group.com.evlin.ios") else {
            crossed = false
            return "✗ App Group UserDefaults nil"
        }

        let hasKey = defaults.object(forKey: "evlin.dar.totalSeconds") != nil
        let seconds = defaults.double(forKey: "evlin.dar.totalSeconds")
        let heartbeat = defaults.object(forKey: "evlin.dar.totalSeconds.heartbeat") as? Date

        var fileValue = "—"
        if let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.evlin.ios")?
            .appendingPathComponent("dar-total-seconds.txt"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            fileValue = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let (kcOK, kcText) = readKeychain()
        crossed = hasKey || fileValue != "—" || kcOK
        let hb = heartbeat.map { $0.formatted(date: .omitted, time: .standard) } ?? "none"

        let udLine = hasKey
            ? "\(String(format: "%.1f", seconds))s (\(String(format: "%.1f", seconds / 60))m)"
            : "missing"
        let header = crossed
            ? "✅ CROSSED on at least one channel"
            : "✗ nothing crossed — run the report above first, then read."
        return """
        \(header)
        App Group UserDefaults: \(udLine)
        App Group file: \(fileValue)
        Keychain: \(kcText)
        heartbeat: \(hb)
        """
    }

    /// Read the number back from the shared keychain access group — the channel
    /// the DAR extension writes via `securityd`. errSecSuccess (0) here means
    /// the number crossed the sandbox through keychain.
    private func readKeychain() -> (ok: Bool, text: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "evlin.dar.totalSeconds",
            kSecAttrAccessGroup as String: "D9FM36P37F.com.evlin.darbridge",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecSuccess, let d = out as? Data, let s = String(data: d, encoding: .utf8) {
            return (true, "✅ \(s)")
        }
        return (false, "SecItemCopyMatching=\(status)")
    }
}

#endif
