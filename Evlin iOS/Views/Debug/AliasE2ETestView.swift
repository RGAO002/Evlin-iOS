// Evlin iOS/Evlin iOS/Views/Debug/AliasE2ETestView.swift
//
// One-page end-to-end test for the DeviceActivityReport → main-app alias
// pipeline. Replaces the messy multi-tab probe pages.
//
// Top half: a fixed, always-visible all-activity DeviceActivityReport. Just
// being on screen makes Apple instantiate the EvlinDeviceActivityReport
// extension, which writes alias data to two channels:
//   1. UserDefaults at key `evlin.aliasSnapshot` (App Group)
//   2. A binary plist file at `<App Group container>/alias-snapshot.plist`
//
// Bottom half: a 1-second timer reads BOTH channels every tick, hydrates
// LocalAliasStore, and shows the result. Lookup field at the bottom lets
// you type any name / bundle id and confirm chat resolution will work.
//
// Pass criteria (matches the brief):
//   - Report shows app rows
//   - File bytes > 0  (or UserDefaults bytes > some empty floor)
//   - Snapshot apps > 0
//   - Apps saved > 0
//   - Lookup hits a real token for "YouTube" / "抖音" / etc.
import SwiftUI
import DeviceActivity
import FamilyControls
import Combine

private extension DeviceActivityReport.Context {
    static let evlinMetadataProbe = Self("evlin.metadataProbe")
}

struct AliasE2ETestView: View {
    @EnvironmentObject private var apiClient: APIClient
    @AppStorage("evlin.childDeviceID") private var childDeviceID: String = ""
    @State private var hydration = LocalAliasStore.ReportHydrationResult.noSnapshot
    @State private var catalogExtraction = LocalAliasStore.ReportCatalogExtractionResult.noSnapshot
    @State private var fileInfo: (bytes: Int, modifiedAt: Date?) = (0, nil)
    @State private var userDefaultsBytes: Int = 0
    @State private var heartbeat: Date? = nil
    @State private var encodeStatus: String = ""
    @State private var uploadStatus: String = ""
    @State private var uploadWorking = false
    @State private var lookupQuery: String = "YouTube"
    @State private var lookupResult: String = ""
    @State private var pollTick: Int = 0
    @State private var refreshID = UUID()

    private let pollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var allActivityFilter: DeviceActivityFilter {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -7, to: end) ?? end.addingTimeInterval(-7 * 86_400)
        return DeviceActivityFilter(
            segment: .daily(during: DateInterval(start: start, end: end)),
            devices: .all
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("This is the only test that matters. The report at top runs the extension. The block below polls the App Group every second and shows what got across.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)

                // 1. The trigger — visible report, fixed height. Apple
                //    instantiates the extension to render this; that's when
                //    writeAliasSnapshot fires inside the extension.
                Section {
                    Text("REPORT EXTENSION (visible — keeps extension alive)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                    Text("First row inside the report must show APP GROUP WRITE STATUS. If apps are listed but write status is failed/not visible, the DAR metadata exists but the bridge to the main app is broken.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                    diagBox {
                        diagRow("Write status", encodeStatus.isEmpty ? "<empty>" : encodeStatus,
                                color: encodeStatus.hasPrefix("ok") ? .green : (encodeStatus.isEmpty ? .red : .orange))
                        diagRow("Snapshot apps", "\(hydration.snapshotApps)",
                                color: hydration.snapshotApps > 0 ? .green : .red)
                        diagRow("Uploadable entries", "\(catalogExtraction.entries.count)",
                                color: catalogExtraction.entries.isEmpty ? .red : .green)
                    }
                    Text("Report viewport below is independently scrollable. If the report is clipped, scroll inside the gray card.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                    reportViewport
                }

                // 2. Two-channel diagnostics.
                Section {
                    Text("APP GROUP CHANNELS")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)

                    diagBox {
                        diagRow("File bytes", "\(fileInfo.bytes)", color: fileInfo.bytes > 0 ? .green : .red)
                        diagRow("File modified", fileInfo.modifiedAt?.formatted(date: .omitted, time: .standard) ?? "<never>",
                                color: fileInfo.modifiedAt == nil ? .red : .secondary)
                        diagRow("UserDefaults bytes", "\(userDefaultsBytes)", color: userDefaultsBytes > 200 ? .green : (userDefaultsBytes > 0 ? .orange : .red))
                        diagRow("Heartbeat", heartbeat?.formatted(date: .omitted, time: .standard) ?? "<never>",
                                color: heartbeat == nil ? .red : .secondary)
                        diagRow("Encode status", encodeStatus.isEmpty ? "<empty>" : encodeStatus,
                                color: encodeStatus.hasPrefix("ok") ? .green : (encodeStatus.isEmpty ? .red : .orange))
                    }
                }

                // 3. Hydrate result.
                Section {
                    Text("HYDRATE RESULT (auto, every 1s)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)

                    diagBox {
                        diagRow("Status", hydration.status,
                                color: hydration.status == "ok" ? .green : .orange)
                        diagRow("Snapshot apps", "\(hydration.snapshotApps)",
                                color: hydration.snapshotApps > 0 ? .green : .red)
                        diagRow("Snapshot categories", "\(hydration.snapshotCategories)")
                        diagRow("Apps saved", "\(hydration.appsSaved)",
                                color: hydration.appsSaved > 0 ? .green : .red)
                        diagRow("Categories saved", "\(hydration.categoriesSaved)")
                        diagRow("App decode failures", "\(hydration.appDecodeFailures)",
                                color: hydration.appDecodeFailures > 0 ? .orange : .secondary)
                        diagRow("Skipped empty apps", "\(hydration.skippedEmptyApps)",
                                color: hydration.skippedEmptyApps > 0 ? .orange : .secondary)
                    }
                }

                // 4. The actual proof — type a name and see if chat would resolve it.
                Section {
                    Text("LOOKUP TEST (the real success criterion)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)

                    VStack(alignment: .leading, spacing: 8) {
                        TextField("YouTube / 抖音 / com.zhihu.ios / Instagram", text: $lookupQuery)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button {
                            runLookup()
                        } label: {
                            Label("Lookup", systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        if !lookupResult.isEmpty {
                            Text(lookupResult)
                                .font(.caption.monospaced())
                                .foregroundStyle(lookupResult.hasPrefix("✓") ? Color.green : Color.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.horizontal, 12)
                }

                // 5. Upload the DAR snapshot as the child app catalog. This is
                //    the X3 minimal proof path: no parent token rendering, just
                //    kid-harvested metadata + token bytes → backend → kid shield.
                Section {
                    Text("DAR SNAPSHOT → BACKEND CATALOG")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)

                    diagBox {
                        diagRow("Child device id", childDeviceID.isEmpty ? "(missing)" : childDeviceID,
                                color: childDeviceID.isEmpty ? .red : .secondary)
                        diagRow("Uploadable entries", "\(catalogExtraction.entries.count)",
                                color: catalogExtraction.entries.isEmpty ? .red : .green)
                        diagRow("Extraction status", catalogExtraction.status,
                                color: catalogExtraction.status == "ok" ? .green : .orange)
                        if let first = catalogExtraction.entries.first {
                            diagRow("First entry", "\(first.displayName) · \(first.tokenKind) · \(first.tokenDataHash)")
                        }
                    }

                    Button {
                        Task { await uploadSnapshotCatalog() }
                    } label: {
                        Label(uploadWorking ? "Uploading snapshot…" : "Upload DAR snapshot catalog",
                              systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(uploadWorking || UUID(uuidString: childDeviceID) == nil || catalogExtraction.entries.isEmpty)
                    .padding(.horizontal, 12)

                    if !uploadStatus.isEmpty {
                        Text(uploadStatus)
                            .font(.caption.monospaced())
                            .foregroundStyle(uploadStatus.hasPrefix("Uploaded") ? Color.green : Color.orange)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                    }
                }

                // 6. Manual force-refresh — bumps the report's id so SwiftUI
                //    rebuilds it and Apple re-instantiates the extension.
                Section {
                    Button {
                        refreshID = UUID()
                    } label: {
                        Label("Force re-run extension", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, 12)
                }

                Text("Tick: \(pollTick)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
            }
            .padding(.vertical, 12)
        }
        .navigationTitle("Alias E2E test")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(pollTimer) { _ in
            pollTick += 1
            refreshAllChannels()
        }
        .onAppear {
            refreshAllChannels()
        }
    }

    // MARK: - Polling

    private var reportViewport: some View {
        ScrollView([.vertical, .horizontal], showsIndicators: true) {
            DeviceActivityReport(.evlinMetadataProbe, filter: allActivityFilter)
                .id(refreshID)
                .frame(width: 720, height: 1_500, alignment: .topLeading)
                .background(Color(.systemGray6))
        }
        .frame(maxWidth: .infinity, minHeight: 540, maxHeight: 620)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
    }

    private func refreshAllChannels() {
        let store = LocalAliasStore.shared
        let groupDefaults = UserDefaults(suiteName: "group.com.evlin.ios")

        fileInfo = store.aliasSnapshotFileInfo()
        userDefaultsBytes = groupDefaults?.data(forKey: "evlin.aliasSnapshot")?.count ?? 0
        heartbeat = groupDefaults?.object(forKey: "evlin.aliasSnapshot.heartbeat") as? Date
        encodeStatus = groupDefaults?.string(forKey: "evlin.aliasSnapshot.encodeStatus") ?? ""

        // Hydrate every poll — idempotent + cheap. Reads file channel first,
        // falls back to UserDefaults inside hydrateFromReportDetailed.
        hydration = store.hydrateFromReportDetailed()
        catalogExtraction = store.catalogEntriesFromReportSnapshot()
    }

    // MARK: - Lookup

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

    private func uploadSnapshotCatalog() async {
        guard let child = UUID(uuidString: childDeviceID) else {
            uploadStatus = "Missing child device id."
            return
        }
        let extraction = LocalAliasStore.shared.catalogEntriesFromReportSnapshot()
        guard !extraction.entries.isEmpty else {
            uploadStatus = "No uploadable DAR snapshot entries. Open a few apps on the kid phone, wait a few minutes, then force re-run the report."
            return
        }

        let apps = extraction.entries.map { entry in
            ChildAppCatalogUploadApp(
                displayName: entry.displayName,
                tokenKind: entry.tokenKind,
                bundleID: entry.bundleID,
                aliases: entry.aliases + ["dar-token-\(entry.tokenDataHash)"],
                tokenAvailable: true,
                tokenDataBase64: entry.tokenData.base64EncodedString()
            )
        }

        uploadWorking = true
        defer { uploadWorking = false }
        do {
            let response = try await apiClient.uploadChildAppCatalog(deviceID: child, apps: apps)
            uploadStatus = "Uploaded \(response.count) DAR catalog entries. First: \(response.apps.first?.displayName ?? "none"). Refresh the parent catalog page next."
        } catch {
            uploadStatus = "Upload failed: \(error.localizedDescription)"
        }
    }

    // MARK: - View helpers

    @ViewBuilder
    private func diagBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func diagRow(_ label: String, _ value: String, color: Color = .secondary) -> some View {
        HStack {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { AliasE2ETestView() }
}
#endif
