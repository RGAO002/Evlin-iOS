import SwiftUI
import FamilyControls
import ManagedSettings

/// Minimal `.child` FamilyActivityPicker spike.
///
/// This is intentionally observational: it does not route through Evlin cards,
/// Brain, or production command handling. The goal is to verify whether Apple's
/// parent-side picker can show authorized child-device apps under Family Sharing.
struct ChildPickerSpikeView: View {
    @AppStorage("appMode") private var appMode = ""
    @AppStorage("evlin.protectionMode") private var protectionMode = "std"
    @AppStorage("evlin.familyID") private var familyID = ""
    @AppStorage("evlin.childDeviceID") private var childDeviceID = ""

    @State private var pickerOpen = false
    @State private var selection = FamilyActivitySelection(includeEntireCategory: true)
    @State private var authStatus = AuthorizationCenter.shared.authorizationStatus
    @State private var authRequestInFlight = false
    @State private var log: [String] = [
        "Open on kid device first: request .child authorization.",
        "Then open on parent device: open picker and inspect what Apple shows."
    ]
    @State private var directShieldStatus = "Not run."
    @State private var remoteShieldStatus = "Not queued."
    @State private var remoteShieldInFlight = false

    private let directShieldStore = ManagedSettingsStore(named: ManagedSettingsStore.Name("evlin.childPickerSpike.direct"))

    private var apps: [ApplicationToken] {
        Array(selection.applicationTokens).sorted { $0.hashValue < $1.hashValue }
    }

    private var categories: [ActivityCategoryToken] {
        Array(selection.categoryTokens).sorted { $0.hashValue < $1.hashValue }
    }

    private var webDomains: [WebDomainToken] {
        Array(selection.webDomainTokens).sorted { $0.hashValue < $1.hashValue }
    }

    private var liveApplications: [Application] {
        Array(selection.applications).sorted {
            ($0.localizedDisplayName ?? $0.bundleIdentifier ?? "") < ($1.localizedDisplayName ?? $1.bundleIdentifier ?? "")
        }
    }

    private var liveCategories: [ActivityCategory] {
        Array(selection.categories).sorted {
            ($0.localizedDisplayName ?? "") < ($1.localizedDisplayName ?? "")
        }
    }

    private var liveWebDomains: [WebDomain] {
        Array(selection.webDomains).sorted { "\($0)" < "\($1)" }
    }

    var body: some View {
        Form {
            Section("Purpose") {
                Text("Tests whether `.child` authorization lets the parent device's Apple FamilyActivityPicker show apps from an authorized kid device. This does not use Evlin AI or any production routing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Auth status", value: "\(authStatus)")
                LabeledContent("App mode", value: appMode.isEmpty ? "<empty>" : appMode)
                LabeledContent("Protection mode", value: protectionMode)
                LabeledContent("Family ID", value: familyID.isEmpty ? "<missing>" : String(familyID.prefix(8)) + "…")
                LabeledContent("Child Device ID", value: childDeviceID.isEmpty ? "<missing>" : String(childDeviceID.prefix(8)) + "…")
                LabeledContent("Auth request", value: authRequestInFlight ? "in flight" : "idle")
                LabeledContent("Selected apps", value: "\(apps.count)")
                LabeledContent("Selected categories", value: "\(categories.count)")
                LabeledContent("Selected web domains", value: "\(webDomains.count)")
            }

            Section("T0.5 Pre-flight") {
                preflightRow("Parent Apple ID is Organizer or Parent/Guardian in Family Sharing.")
                preflightRow("Kid Apple ID is in the same Family Sharing group as Child/Teen.")
                preflightRow("Installed app's signed entitlements include com.apple.developer.family-controls.")
                preflightRow("Record both iOS versions before testing.")
                Text("If `.child` fails, these distinguish setup/provisioning failures from Apple API limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("T1 Kid-device .child authorization") {
                Text("Run this on the kid iPhone. Apple may ask the parent/guardian to authenticate on the kid device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await requestChildAuthorization(context: "Kid-device T1") }
                } label: {
                    if authRequestInFlight {
                        HStack {
                            ProgressView()
                            Text("Requesting .child authorization...")
                        }
                    } else {
                        Label("Request .child authorization", systemImage: "person.badge.shield.checkmark")
                    }
                }
                .disabled(authRequestInFlight)

                Button("Refresh auth status") {
                    refreshAuth()
                    appendLog("auth status = \(authStatus)")
                }
            }

            Section("T1.5 THIS-device .child authorization") {
                Text("Run this on the parent iPhone only after kid-device T1 has approved. This tests whether the parent device also needs a `.child` authorization context before the picker switches to child-device apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await requestChildAuthorization(context: "THIS-device T1.5") }
                } label: {
                    if authRequestInFlight {
                        HStack {
                            ProgressView()
                            Text("Requesting .child on this device...")
                        }
                    } else {
                        Label("Request .child on THIS device", systemImage: "person.2.badge.gearshape")
                    }
                }
                .disabled(authRequestInFlight)

                Text("Expected useful outcomes: approved + picker changes to kid apps, or a specific FamilyControlsError such as invalidAccountType/restricted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("T2 Parent-device picker") {
                Text("Run after kid-device `.child` authorization. If Apple docs hold, the parent device picker should show authorized child-device apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    selection = FamilyActivitySelection(includeEntireCategory: true)
                    appendLog("T2 normal picker opening; auth=\(authStatus), appMode=\(appMode), protectionMode=\(protectionMode)")
                    pickerOpen = true
                } label: {
                    Label("Open parent FamilyActivityPicker", systemImage: "square.grid.2x2")
                }

                Button("Clear local selection") {
                    selection = FamilyActivitySelection(includeEntireCategory: true)
                    appendLog("selection cleared")
                }
            }

            Section("Live metadata returned by picker") {
                if liveApplications.isEmpty && liveCategories.isEmpty && liveWebDomains.isEmpty {
                    Text("No live metadata in current selection.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(liveApplications.enumerated()), id: \.offset) { index, app in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Application \(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(app.localizedDisplayName ?? "(no localizedDisplayName)")
                            Text(app.bundleIdentifier ?? "(no bundleIdentifier)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text("token: \(app.token == nil ? "nil" : "present")")
                                .font(.caption.monospaced())
                                .foregroundStyle(app.token == nil ? .red : .green)
                            if app.token != nil {
                                Button {
                                    Task { await queueRemoteKidShield(for: app) }
                                } label: {
                                    Label("Queue kid lock for this app (15m min)", systemImage: "paperplane.fill")
                                }
                                .disabled(remoteShieldInFlight)
                            }
                        }
                    }

                    ForEach(Array(liveCategories.enumerated()), id: \.offset) { index, category in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Category \(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(category.localizedDisplayName ?? "(no localizedDisplayName)")
                            Text("token: \(category.token == nil ? "nil" : "present")")
                                .font(.caption.monospaced())
                                .foregroundStyle(category.token == nil ? .red : .green)
                        }
                    }

                    if !liveWebDomains.isEmpty {
                        Text("Web domains: \(liveWebDomains.count)")
                            .font(.caption.monospaced())
                    }
                }
            }

            Section("Label(token) render") {
                if apps.isEmpty && categories.isEmpty && webDomains.isEmpty {
                    Text("Select apps/categories in the picker first.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(apps.enumerated()), id: \.offset) { index, token in
                        TokenLabelRow(kind: "App", index: index, hash: token.hashValue) {
                            Label(token).labelStyle(.titleAndIcon)
                        }
                    }
                    ForEach(Array(categories.enumerated()), id: \.offset) { index, token in
                        TokenLabelRow(kind: "Category", index: index, hash: token.hashValue) {
                            Label(token).labelStyle(.titleAndIcon)
                        }
                    }
                    ForEach(Array(webDomains.enumerated()), id: \.offset) { index, token in
                        TokenLabelRow(kind: "Web", index: index, hash: token.hashValue) {
                            Label(token).labelStyle(.titleAndIcon)
                        }
                    }
                }
            }

            Section("★ Parent block list — Label(token) + lock (the elegant path)") {
                Text("Each row is Label(token): the parent device renders the kid app's real name + icon natively — NO string extraction, NO OCR, NO screenshots. Tap the lock to route that token to the kid. This is the iOS-iOS path, the same way Opal shows a selection. (`.applications` names are nil — see the section above — but Label renders them anyway.)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let lockable = liveApplications.filter { $0.token != nil }
                if lockable.isEmpty {
                    Text("Pick kid apps in the picker above first.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(lockable.enumerated()), id: \.offset) { _, app in
                        if let token = app.token {
                            HStack(spacing: 12) {
                                Label(token)
                                    .labelStyle(.titleAndIcon)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Button {
                                    Task { await queueRemoteKidShield(for: app) }
                                } label: {
                                    Image(systemName: "lock.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .disabled(remoteShieldInFlight)
                            }
                        }
                    }
                    if !remoteShieldStatus.isEmpty {
                        Text(remoteShieldStatus)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("T3 Token encoding probe") {
                Text("Checks whether selected ApplicationToken can round-trip locally. This is prerequisite for sending through the command queue later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Test first app token JSON + plist roundtrip") {
                    testFirstAppTokenRoundtrip()
                }
                .disabled(apps.isEmpty)
            }

            Section("T3.5 Direct parent-device shield disproof") {
                Text("Optional: sets the selected app tokens on this device's ManagedSettingsStore for 60 seconds. Expected result: it should not affect the kid device. Verify by physically opening the app on the kid phone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Status", value: directShieldStatus)

                Button(role: .destructive) {
                    runDirectShieldForOneMinute()
                } label: {
                    Label("Direct shield selected apps on THIS device for 60s", systemImage: "lock.fill")
                }
                .disabled(apps.isEmpty)

                Button("Clear direct shield") {
                    directShieldStore.shield.applications = nil
                    directShieldStatus = "Cleared."
                    appendLog("direct shield cleared")
                }
            }

            Section("T4 Parent → backend → kid shield") {
                Text("Select the kid-only app (for example Cat Quest) in the picker, then tap its per-app queue button above. This uploads exactly that selected token as a debug catalog entry, then queues the existing child lock command. Keep Evlin open on the kid phone so CommandPoller can fetch it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Status", value: remoteShieldStatus)

                Button("Queue first selected app to kid (15m min)") {
                    Task { await queueFirstSelectedAppRemoteShield() }
                }
                .disabled(remoteShieldInFlight || liveApplications.first(where: { $0.token != nil }) == nil)
            }

            Section("Log") {
                ForEach(log, id: \.self) { line in
                    Text(line)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(".child picker spike")
        .navigationBarTitleDisplayMode(.inline)
        .familyActivityPicker(isPresented: $pickerOpen, selection: $selection)
        .onChange(of: pickerOpen) { _, isOpen in
            if !isOpen {
                appendPickerSummary()
            }
        }
        .onAppear {
            refreshAuth()
        }
    }

    @ViewBuilder
    private func preflightRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("□").font(.caption.monospaced())
            Text(text).font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    private func refreshAuth() {
        authStatus = AuthorizationCenter.shared.authorizationStatus
    }

    private func appendLog(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.insert("\(stamp) \(line)", at: 0)
    }

    @MainActor
    private func requestChildAuthorization(context: String) async {
        guard !authRequestInFlight else {
            appendLog("\(context): ignored duplicate .child request; already in flight")
            return
        }

        authRequestInFlight = true
        refreshAuth()
        appendLog("\(context): → starting .child request; status before=\(authStatus)")

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run {
                if authRequestInFlight {
                    appendLog("\(context): … .child request still waiting after 8s; if no Apple sheet appeared, the OS/account context may be suppressing it")
                }
            }
        }

        defer {
            timeoutTask.cancel()
            authRequestInFlight = false
            refreshAuth()
        }

        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .child)
            refreshAuth()
            appendLog("\(context): ✓ .child approved; status=\(authStatus)")
        } catch let error as FamilyControlsError {
            appendLog("\(context): ✗ .child failed: \(describe(error))")
            refreshAuth()
        } catch {
            appendLog("\(context): ✗ .child failed non-FamilyControlsError: \(error)")
            refreshAuth()
        }
    }

    private func describe(_ error: FamilyControlsError) -> String {
        switch error {
        case .restricted:
            return "restricted — FamilyControls restricted or entitlement/provisioning unavailable"
        case .unavailable:
            return "unavailable — FamilyControls unavailable on this device/account"
        case .invalidAccountType:
            return "invalidAccountType — this Apple ID is not eligible as the requested member type"
        case .invalidArgument:
            return "invalidArgument"
        case .authorizationConflict:
            return "authorizationConflict — another authorization mode may already be active"
        case .authorizationCanceled:
            return "authorizationCanceled — user canceled"
        case .networkError:
            return "networkError — Apple Family service/network issue"
        case .authenticationMethodUnavailable:
            return "authenticationMethodUnavailable — required parent/guardian auth method unavailable"
        @unknown default:
            return "unknown FamilyControlsError: \(error)"
        }
    }

    private func appendPickerSummary() {
        refreshAuth()
        appendLog(
            "picker closed: apps=\(apps.count), cats=\(categories.count), webs=\(webDomains.count), liveApps=\(liveApplications.count), liveCats=\(liveCategories.count), status=\(authStatus)"
        )
        if !liveApplications.isEmpty {
            for app in liveApplications.prefix(5) {
                appendLog("live app: \(app.localizedDisplayName ?? "?") | \(app.bundleIdentifier ?? "?") | token=\(app.token == nil ? "nil" : "present")")
            }
        }
    }

    private func testFirstAppTokenRoundtrip() {
        guard let token = apps.first else {
            appendLog("roundtrip skipped: no app token")
            return
        }

        do {
            let data = try JSONEncoder().encode(token)
            _ = try JSONDecoder().decode(ApplicationToken.self, from: data)
            appendLog("JSON roundtrip ✓ bytes=\(data.count), prefix=\(data.base64EncodedString().prefix(12))")
        } catch {
            appendLog("JSON roundtrip ✗ \(error)")
        }

        do {
            let data = try PropertyListEncoder().encode(token)
            _ = try PropertyListDecoder().decode(ApplicationToken.self, from: data)
            appendLog("plist roundtrip ✓ bytes=\(data.count), prefix=\(data.base64EncodedString().prefix(12))")
        } catch {
            appendLog("plist roundtrip ✗ \(error)")
        }
    }

    private func runDirectShieldForOneMinute() {
        let tokenSet = Set(apps)
        guard !tokenSet.isEmpty else { return }
        directShieldStore.shield.applications = tokenSet
        directShieldStatus = "Applied \(tokenSet.count) app token(s) on this device for 60s."
        appendLog("direct shield applied to THIS device only; physically check kid phone for no effect")

        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            directShieldStore.shield.applications = nil
            directShieldStatus = "Auto-cleared after 60s."
            appendLog("direct shield auto-cleared")
        }
    }

    @MainActor
    private func queueFirstSelectedAppRemoteShield() async {
        guard let app = liveApplications.first(where: { $0.token != nil }) else {
            appendLog("remote shield skipped: picker selection has no app token")
            remoteShieldStatus = "No selected app token."
            return
        }
        await queueRemoteKidShield(for: app)
    }

    @MainActor
    private func queueRemoteKidShield(for app: Application) async {
        guard !remoteShieldInFlight else { return }
        guard let familyUUID = UUID(uuidString: familyID),
              let childUUID = UUID(uuidString: childDeviceID) else {
            remoteShieldStatus = "Missing family/child IDs."
            appendLog("remote shield ✗ missing evlin.familyID or evlin.childDeviceID")
            return
        }
        guard let upload = makeCatalogUploadApp(from: app) else {
            remoteShieldStatus = "Selected app had no token."
            appendLog("remote shield ✗ selected app has no token: \(app.localizedDisplayName ?? "?")")
            return
        }

        remoteShieldInFlight = true
        remoteShieldStatus = "Uploading token and queueing command..."
        let display = upload.displayName
        appendLog("remote shield → upload+queue \(display) bundle=\(upload.bundleID ?? "<nil>")")
        defer { remoteShieldInFlight = false }

        do {
            let api = APIClient()
            let uploaded = try await api.uploadChildAppCatalog(deviceID: childUUID, apps: [upload])
            guard let entry = uploaded.apps.first else {
                remoteShieldStatus = "Upload returned no catalog entries."
                appendLog("remote shield ✗ upload returned no entries")
                return
            }
            let queued = try await api.lockChildCatalogApp(
                familyID: familyUUID,
                childDeviceID: childUUID,
                appID: entry.id,
                durationMinutes: 15
            )
            remoteShieldStatus = "Queued \(queued.targetDisplay) command \(queued.commandID.uuidString.prefix(8))…"
            appendLog("remote shield ✓ queued command=\(queued.commandID) target=\(queued.targetDisplay). Open kid Evlin and test the app.")
        } catch {
            remoteShieldStatus = "Failed: \(error.localizedDescription)"
            appendLog("remote shield ✗ \(error)")
        }
    }

    private func makeCatalogUploadApp(from app: Application) -> ChildAppCatalogUploadApp? {
        guard let token = app.token else { return nil }
        let tokenData: Data
        do {
            tokenData = try PropertyListEncoder().encode(token)
            _ = try PropertyListDecoder().decode(ApplicationToken.self, from: tokenData)
        } catch {
            appendLog("remote shield ✗ token plist roundtrip failed for \(app.localizedDisplayName ?? "?"): \(error)")
            return nil
        }

        let display = app.localizedDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundle = app.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (display?.isEmpty == false)
            ? display!
            : (bundle?.isEmpty == false ? bundle! : "Selected app")
        var aliases = [displayName]
        if let bundle, !bundle.isEmpty {
            aliases.append(bundle)
        }

        return ChildAppCatalogUploadApp(
            displayName: displayName,
            tokenKind: "app",
            bundleID: (bundle?.isEmpty == false) ? bundle : nil,
            aliases: aliases,
            tokenAvailable: true,
            tokenDataBase64: tokenData.base64EncodedString()
        )
    }
}

private struct TokenLabelRow<Content: View>: View {
    let kind: String
    let index: Int
    let hash: Int
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(kind) #\(index + 1)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("hash \(hash)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            content()
        }
    }
}
