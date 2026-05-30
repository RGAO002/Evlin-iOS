import DeviceActivity
import FamilyControls
import SwiftUI

/// Main-app screen for an audit-only Lock Activity Review. It is opened
/// manually from Settings and is never awaited by chat or lock execution.
struct LockActivityReviewScreen: View {
    @EnvironmentObject private var screenTimeManager: ScreenTimeManager
    @State private var refreshID = UUID()

    private var interval: DateInterval {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -1, to: end)
            ?? end.addingTimeInterval(-24 * 60 * 60)
        return DateInterval(start: start, end: end)
    }

    /// The filter is a hint based on current managed selection. The report
    /// scene re-reads the authoritative App Group window log and filters again.
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

    var body: some View {
        List {
            Section {
                Text(EvlinReceiptCopy.reviewIsBestEffort)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    refreshID = UUID()
                } label: {
                    Label("Refresh review", systemImage: "arrow.clockwise")
                }
            } header: {
                Text("About this review")
            }

            Section("Locked-app usage (last 24h)") {
                DeviceActivityReport(.evlinLockReview, filter: filter)
                    .id(refreshID)
                    .frame(minHeight: 360)
            }
        }
        .navigationTitle("Lock activity review")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            screenTimeManager.refreshAuthorizationStatus()
        }
    }
}

private extension DeviceActivityReport.Context {
    static let evlinLockReview = Self("evlin.lockReview")
}
