import DeviceActivity
import FamilyControls
import SwiftUI
import UIKit
import Security

struct DeviceActivityReportMetadataProbeView: View {
    enum ReportScope: String, CaseIterable, Identifiable {
        case allActivityNoUsers = "All, no users"
        case allActivity = "All + users"
        case selectedNoUsers = "Selection, no users"
        case selected = "Selection + users"

        var id: String { rawValue }
    }

    @EnvironmentObject private var screenTimeManager: ScreenTimeManager
    @State private var refreshID = UUID()
    @State private var scope: ReportScope = .allActivityNoUsers
    @State private var pasteboardProbeResult: String = ""
    @State private var keychainProbeResult: String = ""

    private var interval: DateInterval {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -7, to: end) ?? end.addingTimeInterval(-7 * 24 * 60 * 60)
        return DateInterval(start: start, end: end)
    }

    private var filter: DeviceActivityFilter {
        DeviceActivityFilter(
            segment: .daily(during: interval),
            users: .all,
            devices: .all,
            applications: screenTimeManager.selectedApps.applicationTokens,
            categories: screenTimeManager.selectedApps.categoryTokens,
            webDomains: screenTimeManager.selectedApps.webDomainTokens
        )
    }

    private var filterNoUsers: DeviceActivityFilter {
        DeviceActivityFilter(
            segment: .daily(during: interval),
            devices: .all,
            applications: screenTimeManager.selectedApps.applicationTokens,
            categories: screenTimeManager.selectedApps.categoryTokens,
            webDomains: screenTimeManager.selectedApps.webDomainTokens
        )
    }

    private var allActivityFilter: DeviceActivityFilter {
        DeviceActivityFilter(
            segment: .daily(during: interval),
            users: .all,
            devices: .all
        )
    }

    private var allActivityFilterNoUsers: DeviceActivityFilter {
        DeviceActivityFilter(
            segment: .daily(during: interval),
            devices: .all
        )
    }

    private var activeFilter: DeviceActivityFilter {
        switch scope {
        case .allActivityNoUsers:
            return allActivityFilterNoUsers
        case .allActivity:
            return allActivityFilter
        case .selectedNoUsers:
            return filterNoUsers
        case .selected:
            return filter
        }
    }

    var body: some View {
        List {
            Section {
                Text(
                    """
                    This opens one real DeviceActivityReport extension at a time. "All activity" is the report alias sync should use; "Managed selection" is only a filter comparison.

                    Only the report view matters. Evlin does not read these names back into the main app.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                LabeledContent("Selected app tokens", value: "\(screenTimeManager.selectedApps.applicationTokens.count)")
                LabeledContent("Selected category tokens", value: "\(screenTimeManager.selectedApps.categoryTokens.count)")
                LabeledContent("Selected web tokens", value: "\(screenTimeManager.selectedApps.webDomainTokens.count)")
                LabeledContent("Screen Time auth") {
                    Text(screenTimeManager.isAuthorized ? "approved" : "not approved")
                        .foregroundStyle(screenTimeManager.isAuthorized ? .green : .red)
                }

                Picker("Report scope", selection: $scope) {
                    ForEach(ReportScope.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: scope) { _, _ in
                    refreshID = UUID()
                }

                Button {
                    refreshID = UUID()
                } label: {
                    Label("Refresh report", systemImage: "arrow.clockwise")
                }

                // DAR-export probe (PASTEBOARD channel). The report extension
                // writes "EVLIN_DAR_PB apps=N first=<bundleID> ..." to the general
                // pasteboard when it renders below. If this read shows that marker
                // — especially a real bundleID — the pasteboard crosses the DAR
                // sandbox and we have an export channel for the one datum nothing
                // else gives us. Order: let the report render first, THEN read.
                Button {
                    let s = UIPasteboard.general.string ?? ""
                    if s.contains("EVLIN_DAR_PB") {
                        pasteboardProbeResult = "✅ CROSSED — \(s)"
                    } else if s.isEmpty {
                        pasteboardProbeResult = "✗ pasteboard empty (render the report below first, then read)"
                    } else {
                        pasteboardProbeResult = "✗ no DAR marker. Pasteboard holds: \(s.prefix(120))"
                    }
                } label: {
                    Label("Read pasteboard (DAR export probe)", systemImage: "doc.on.clipboard")
                }

                if !pasteboardProbeResult.isEmpty {
                    Text(pasteboardProbeResult)
                        .font(.caption.monospaced())
                        .foregroundStyle(pasteboardProbeResult.hasPrefix("✅") ? .green : .orange)
                        .textSelection(.enabled)
                }

                // DAR-export probe (KEYCHAIN channel). The report extension writes
                // the marker to a shared keychain access group. If this read
                // returns it, securityd crossed the DAR sandbox. Also check the
                // "KC:SecItemAdd=N" suffix in the report's write-status below —
                // 0 means the DAR write itself succeeded (and proves DAR ran).
                Button {
                    keychainProbeResult = readKeychainProbe()
                } label: {
                    Label("Read keychain (DAR export probe)", systemImage: "key.fill")
                }

                if !keychainProbeResult.isEmpty {
                    Text(keychainProbeResult)
                        .font(.caption.monospaced())
                        .foregroundStyle(keychainProbeResult.hasPrefix("✅") ? .green : .orange)
                        .textSelection(.enabled)
                }
            } header: {
                Text("How to read this")
            }

            Section("Live report extension view") {
                Text("Active scope: \(scope.rawValue). If auth is not approved, fix Screen Time authorization first.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                DeviceActivityReport(.evlinMetadataProbe, filter: activeFilter)
                    .id(refreshID)
                    .frame(minHeight: 520)
            }
        }
        .navigationTitle("Report metadata probe")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            screenTimeManager.refreshAuthorizationStatus()
        }
    }

    private func readKeychainProbe() -> String {
        let group = "D9FM36P37F.com.evlin.darbridge"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "evlin.dar.export",
            kSecAttrAccessGroup as String: group,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecSuccess, let data = out as? Data,
           let s = String(data: data, encoding: .utf8) {
            return "✅ CROSSED — \(s)"
        }
        return "✗ SecItemCopyMatching=\(status) (no item / blocked). Render the report below first, then read."
    }
}

private extension DeviceActivityReport.Context {
    static let evlinMetadataProbe = Self("evlin.metadataProbe")
}
