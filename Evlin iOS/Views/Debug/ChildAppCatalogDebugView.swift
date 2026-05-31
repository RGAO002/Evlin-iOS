import SwiftUI
import FamilyControls
import ManagedSettings

struct ChildAppCatalogDebugView: View {
    @EnvironmentObject private var apiClient: APIClient
    @AppStorage("evlin.familyID") private var familyID: String = ""
    @AppStorage("evlin.childDeviceID") private var childDeviceID: String = ""
    @AppStorage("appMode") private var appMode: String = ""

    @State private var pickerOpen = false
    @State private var pickerSelection = FamilyActivitySelection(includeEntireCategory: true)
    @State private var rows: [ChildAppCatalogEntryDTO] = []
    @State private var status: String = "Ready."
    @State private var working = false
    @State private var durationMinutes = 15

    private var familyUUID: UUID? { UUID(uuidString: familyID) }
    private var childUUID: UUID? { UUID(uuidString: childDeviceID) }
    private var pickedAppTokens: [ApplicationToken] {
        Array(pickerSelection.applicationTokens).sorted { $0.hashValue < $1.hashValue }
    }
    private var pickedCategoryTokens: [ActivityCategoryToken] {
        Array(pickerSelection.categoryTokens).sorted { $0.hashValue < $1.hashValue }
    }
    private var pickedTokenCount: Int {
        pickedAppTokens.count + pickedCategoryTokens.count
    }

    var body: some View {
        Form {
            Section("Pairing") {
                LabeledContent("Family") { idText(familyID) }
                LabeledContent("Child") { idText(childDeviceID) }
                LabeledContent("API") { idText(apiClient.baseURL) }
            }

            Section {
                Text("Kid phone only. Open Apple's picker, choose apps and/or whole categories, then upload the encoded tokens. This tests whether the parent phone can decode and render Kid-created FamilyControls tokens with Label(token).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    pickerOpen = true
                } label: {
                    Label("1. Open Kid Apple picker", systemImage: "square.grid.2x2")
                }

                LabeledContent("Picked app tokens") {
                    Text("\(pickedAppTokens.count)")
                        .foregroundStyle(pickedAppTokens.isEmpty ? .red : .green)
                }
                LabeledContent("Picked category tokens") {
                    Text("\(pickedCategoryTokens.count)")
                        .foregroundStyle(pickedCategoryTokens.isEmpty ? Color.secondary : Color.green)
                }

                if pickedTokenCount == 0 {
                    Text("No app/category tokens picked yet. If you choose a whole category like Social, it appears under category tokens, not app tokens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(pickedAppTokens.enumerated()), id: \.offset) { index, token in
                        HStack {
                            Text("App #\(index + 1)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Label(token)
                                .labelStyle(.titleAndIcon)
                            Spacer()
                            Text("hash \(token.hashValue)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    ForEach(Array(pickedCategoryTokens.enumerated()), id: \.offset) { index, token in
                        HStack {
                            Text("Cat #\(index + 1)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Label(token)
                                .labelStyle(.titleAndIcon)
                            Spacer()
                            Text("hash \(token.hashValue)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Button {
                    Task { await uploadPickedTokens() }
                } label: {
                    Label(working ? "Uploading…" : "2. Upload picked tokens to parent picker",
                          systemImage: "square.and.arrow.up")
                }
                .disabled(working || childUUID == nil || pickedTokenCount == 0)

                if appMode == "child" {
                    Button {
                        Task { await pollKidCommandsNow() }
                    } label: {
                        Label("4. Kid poll pending lock commands now",
                              systemImage: "arrow.down.circle")
                    }
                    .disabled(working || childUUID == nil)
                }
            } header: {
                Text("K side: picker token upload")
            } footer: {
                Text("This intentionally sends encoded ApplicationToken bytes through the local backend for the experiment. Do not treat this as production privacy design.")
            }

            Section {
                Stepper("Duration: \(durationMinutes) min", value: $durationMinutes, in: 15...240, step: 15)

                Button {
                    Task { await refreshParentCatalog() }
                } label: {
                    Label(working ? "Refreshing…" : "3. Refresh parent token catalog",
                          systemImage: "arrow.clockwise")
                }
                .disabled(working || childUUID == nil)

                if rows.isEmpty {
                    Text("No uploaded kid tokens loaded.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        ParentTokenRow(
                            row: row,
                            working: working,
                            canLock: familyUUID != nil && childUUID != nil,
                            onLock: { Task { await lock(row) } }
                        )
                    }
                }
            } header: {
                Text("P side: decode, render, lock")
            } footer: {
                Text("If the parent can render names/icons here, cross-device Label(token) works. Lock sends the same encoded token back to the kid device for execution.")
            }

            Section("Status") {
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Kid picker token transfer")
        .navigationBarTitleDisplayMode(.inline)
        .familyActivityPicker(isPresented: $pickerOpen, selection: $pickerSelection)
        .task { await refreshParentCatalog() }
    }

    @ViewBuilder
    private func idText(_ value: String) -> some View {
        Text(value.isEmpty ? "(missing)" : value)
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func uploadPickedTokens() async {
        guard let child = childUUID else {
            status = "Missing child device id."
            return
        }
        var apps = pickedAppTokens.enumerated().compactMap { index, token -> ChildAppCatalogUploadApp? in
            guard let data = Self.encodeApplicationToken(token) else { return nil }
            return ChildAppCatalogUploadApp(
                displayName: "Kid picker app \(index + 1)",
                tokenKind: "app",
                bundleID: nil,
                aliases: ["kid-picker-app-\(index + 1)", "token-hash-\(token.hashValue)"],
                tokenAvailable: true,
                tokenDataBase64: data.base64EncodedString()
            )
        }
        apps.append(contentsOf: pickedCategoryTokens.enumerated().compactMap { index, token -> ChildAppCatalogUploadApp? in
            guard let data = Self.encodeCategoryToken(token) else { return nil }
            return ChildAppCatalogUploadApp(
                displayName: "Kid picker category \(index + 1)",
                tokenKind: "category",
                bundleID: nil,
                aliases: ["kid-picker-category-\(index + 1)", "token-hash-\(token.hashValue)"],
                tokenAvailable: true,
                tokenDataBase64: data.base64EncodedString()
            )
        })
        guard !apps.isEmpty else {
            status = "Could not encode any picked app/category token."
            return
        }

        working = true
        defer { working = false }
        do {
            let response = try await apiClient.uploadChildAppCatalog(deviceID: child, apps: apps)
            rows = response.apps
            status = "Uploaded \(response.count) encoded token(s). Now refresh on parent and check Label(token)."
        } catch {
            status = "Upload failed: \(error.localizedDescription)"
        }
    }

    private func pollKidCommandsNow() async {
        guard let child = childUUID else {
            status = "Missing child device id."
            return
        }
        working = true
        defer { working = false }
        CommandPoller.shared.start(deviceID: child, apiClient: apiClient)
        await CommandPoller.shared.pollOnce()
        status = "Kid command poll requested for \(child.uuidString). Check whether pending commands ack or shield applies."
    }

    private func refreshParentCatalog() async {
        guard let child = childUUID else {
            status = "Missing child device id."
            return
        }
        working = true
        defer { working = false }
        do {
            let response = try await apiClient.fetchChildAppCatalog(childDeviceID: child)
            rows = response.apps
            status = "Loaded \(response.apps.count) uploaded kid token(s)."
        } catch {
            status = "Refresh failed: \(error.localizedDescription)"
        }
    }

    private func lock(_ row: ChildAppCatalogEntryDTO) async {
        guard let family = familyUUID, let child = childUUID else {
            status = "Missing family or child id."
            return
        }
        working = true
        defer { working = false }
        do {
            let response = try await apiClient.lockChildCatalogApp(
                familyID: family,
                childDeviceID: child,
                appID: row.id,
                durationMinutes: durationMinutes
            )
            status = "Queued \(response.targetDisplay) for \(response.durationMinutes ?? 0) min. Command \(response.commandID.uuidString)"
        } catch {
            status = "Lock failed: \(error.localizedDescription)"
        }
    }

    private static func encodeApplicationToken(_ token: ApplicationToken) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(token)
    }

    private static func encodeCategoryToken(_ token: ActivityCategoryToken) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(token)
    }
}

private struct ParentTokenRow: View {
    let row: ChildAppCatalogEntryDTO
    let working: Bool
    let canLock: Bool
    let onLock: () -> Void

    private var decodedAppToken: ApplicationToken? {
        guard let encoded = row.tokenDataBase64,
              let data = Data(base64Encoded: encoded)
        else { return nil }
        if let token = try? JSONDecoder().decode(ApplicationToken.self, from: data) {
            return token
        }
        return try? PropertyListDecoder().decode(ApplicationToken.self, from: data)
    }

    private var decodedCategoryToken: ActivityCategoryToken? {
        guard let encoded = row.tokenDataBase64,
              let data = Data(base64Encoded: encoded)
        else { return nil }
        if let token = try? JSONDecoder().decode(ActivityCategoryToken.self, from: data) {
            return token
        }
        return try? PropertyListDecoder().decode(ActivityCategoryToken.self, from: data)
    }

    private var tokenByteCount: Int {
        guard let encoded = row.tokenDataBase64,
              let data = Data(base64Encoded: encoded)
        else { return 0 }
        return data.count
    }

    private var decodedTokenKindLabel: String {
        if row.tokenKind == "category" {
            return decodedCategoryToken == nil ? "category decode failed" : "category decoded"
        }
        return decodedAppToken == nil ? "app decode failed" : "app decoded"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if row.tokenKind == "category", let token = decodedCategoryToken {
                    Label(token)
                        .labelStyle(.titleAndIcon)
                } else if let token = decodedAppToken {
                    Label(token)
                        .labelStyle(.titleAndIcon)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName)
                        .font(.body.weight(.semibold))
                    Text("\(decodedTokenKindLabel) · \(tokenByteCount) bytes")
                        .font(.caption)
                        .foregroundStyle(
                            decodedTokenKindLabel.contains("failed") ? .red : .secondary
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Lock") { onLock() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(working || !canLock || decodedTokenKindLabel.contains("failed"))
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack { ChildAppCatalogDebugView().environmentObject(APIClient()) }
}
