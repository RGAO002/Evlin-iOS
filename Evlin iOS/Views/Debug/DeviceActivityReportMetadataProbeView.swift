import DeviceActivity
import FamilyControls
import SwiftUI

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
}

private extension DeviceActivityReport.Context {
    static let evlinMetadataProbe = Self("evlin.metadataProbe")
}
