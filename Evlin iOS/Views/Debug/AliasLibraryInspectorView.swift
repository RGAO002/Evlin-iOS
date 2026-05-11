// Evlin iOS/Evlin iOS/Views/Debug/AliasLibraryInspectorView.swift
//
// Read-out of LocalAliasStore after DeviceActivityReport hydration. This is
// the "did the alias-from-report path actually work" pane.
//
// Flow being verified:
//   1. Kid uses some apps → iOS aggregates usage data
//   2. Main app shows DeviceActivityReportMetadataProbeView →
//      EvlinDeviceActivityReport extension runs, writes alias snapshot to
//      App Group key `evlin.aliasSnapshot`
//   3. This view calls `LocalAliasStore.shared.hydrateFromReport()` →
//      every (token, bundleID, displayName) becomes a chat-resolvable alias
//   4. The list below lets you eyeball: "is `Instagram` keyed to a token?"
import SwiftUI
import FamilyControls
import ManagedSettings
import DeviceActivity

private extension DeviceActivityReport.Context {
    static let evlinMetadataProbe = Self("evlin.metadataProbe")
}

struct AliasLibraryInspectorView: View {
    @State private var hydration = LocalAliasStore.ReportHydrationResult.noSnapshot
    @State private var lookupQuery: String = "Instagram"
    @State private var lookupResult: String = ""
    @State private var reportRefreshID = UUID()

    private var interval: DateInterval {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -7, to: end) ?? end.addingTimeInterval(-7 * 24 * 60 * 60)
        return DateInterval(start: start, end: end)
    }

    private var allActivityFilter: DeviceActivityFilter {
        DeviceActivityFilter(
            segment: .daily(during: interval),
            devices: .all
        )
    }

    var body: some View {
        Form {
            Section {
                Text("This page first runs the all-activity DeviceActivityReport below. Once it shows app rows and writes a non-empty snapshot, tap Hydrate now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    reportRefreshID = UUID()
                } label: {
                    Label("Run all-activity report", systemImage: "chart.bar.doc.horizontal")
                }

                Button {
                    hydration = LocalAliasStore.shared.hydrateFromReportDetailed()
                } label: {
                    Label("Hydrate now", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)

                LabeledContent("Hydrate status") {
                    Text(hydration.status)
                        .font(.caption.monospaced())
                        .foregroundStyle(hydration.status == "ok" ? .green : .orange)
                }
                LabeledContent("Apps saved") { Text("\(hydration.appsSaved)") }
                LabeledContent("Categories saved") { Text("\(hydration.categoriesSaved)") }
                LabeledContent("Snapshot apps") { Text("\(hydration.snapshotApps)") }
                LabeledContent("Snapshot categories") { Text("\(hydration.snapshotCategories)") }
                LabeledContent("App token decode failures") { Text("\(hydration.appDecodeFailures)") }
                LabeledContent("Category token decode failures") { Text("\(hydration.categoryDecodeFailures)") }
                LabeledContent("Skipped empty app rows") { Text("\(hydration.skippedEmptyApps)") }
                if let updated = hydration.generatedAt {
                    LabeledContent("Snapshot generated") {
                        Text(updated.formatted(date: .abbreviated, time: .standard))
                            .font(.caption.monospaced())
                    }
                }
            }

            Section("All-activity report writer") {
                Text("Leave this visible until it shows app rows and Alias snapshot write says ok bytes > 101. Then tap Hydrate now above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DeviceActivityReport(.evlinMetadataProbe, filter: allActivityFilter)
                    .id(reportRefreshID)
                    .frame(minHeight: 520)
            }

            Section("Extension heartbeat (diagnostic)") {
                Text("Tells you whether the extension is actually running the latest code, vs stale build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let groupDefaults = UserDefaults(suiteName: "group.com.evlin.ios")
                let heartbeat = groupDefaults?.object(forKey: "evlin.aliasSnapshot.heartbeat") as? Date
                let diag = groupDefaults?.string(forKey: "evlin.aliasSnapshot.diag") ?? ""
                let encodeStatus = groupDefaults?.string(forKey: "evlin.aliasSnapshot.encodeStatus") ?? ""
                let snapshotBytes = groupDefaults?.data(forKey: "evlin.aliasSnapshot")?.count ?? 0
                LabeledContent("Last heartbeat") {
                    Text(heartbeat?.formatted(date: .abbreviated, time: .standard) ?? "<never>")
                        .font(.caption.monospaced())
                        .foregroundStyle(heartbeat == nil ? .red : .secondary)
                }
                LabeledContent("Counts seen") {
                    Text(diag.isEmpty ? "<empty>" : diag)
                        .font(.caption.monospaced())
                        .foregroundStyle(diag.isEmpty ? .red : .secondary)
                }
                LabeledContent("Encode status") {
                    Text(encodeStatus.isEmpty ? "<empty>" : encodeStatus)
                        .font(.caption.monospaced())
                        .foregroundStyle(encodeStatus.hasPrefix("ok") ? .green : (encodeStatus.isEmpty ? .red : .orange))
                        .lineLimit(3)
                }
                LabeledContent("Snapshot bytes") { Text("\(snapshotBytes)") }
                LabeledContent("Decoded snapshot bytes") { Text("\(hydration.snapshotBytes)") }
            }

            Section("Lookup test") {
                Text("Type any name / bundle ID parents might use in chat. Lookup is case-insensitive against keys saved by `saveApplicationAliases`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Instagram", text: $lookupQuery)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button {
                    runLookup()
                } label: {
                    Label("Lookup", systemImage: "magnifyingglass")
                }
                if !lookupResult.isEmpty {
                    Text(lookupResult)
                        .font(.caption.monospaced())
                        .foregroundStyle(lookupResult.hasPrefix("✓") ? Color.green : Color.orange)
                }
            }
        }
        .navigationTitle("Alias library")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Auto-hydrate so the page starts in a useful state.
            hydration = LocalAliasStore.shared.hydrateFromReportDetailed()
        }
    }

    private func runLookup() {
        let store = LocalAliasStore.shared
        let q = lookupQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { lookupResult = "(empty query)"; return }
        if store.applicationToken(forLookupKey: q) != nil {
            let bid = store.primaryBundleID(forDisplayOrHint: q)
            lookupResult = "✓ App alias hit: \"\(q)\" → token (bundle: \(bid ?? "—"))"
            return
        }
        if store.categoryToken(forName: q) != nil {
            lookupResult = "✓ Category alias hit: \"\(q)\" → category token"
            return
        }
        lookupResult = "✗ No alias for \"\(q)\". Either Apple hasn't seen kid use it, or hydration didn't run."
    }
}

#if DEBUG
#Preview {
    NavigationStack { AliasLibraryInspectorView() }
}
#endif
