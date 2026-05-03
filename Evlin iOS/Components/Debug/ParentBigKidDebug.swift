import SwiftUI

#if DEBUG
/// Floating wand pill for the parent shell. Tap → sheet with the three
/// big-kid parent-side actions wired to the FastAPI `/api/v1/parent/*`
/// endpoints. Lets you single-device test the full child loop without
/// shelling out to curl.
struct ParentBigKidDebugButton: View {
    @State private var showSheet: Bool = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                Text("BigKid")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            ParentBigKidDebugSheet()
        }
    }
}

private struct ParentBigKidDebugSheet: View {
    @EnvironmentObject private var apiClient: APIClient
    @AppStorage("evlin.childDeviceID") private var childDeviceID: String = ""
    @Environment(\.dismiss) private var dismiss

    @State private var reason: String = "kept scrolling after time was up"
    @State private var status: String = "Ready."
    @State private var working: Bool = false

    @State private var pendingReflectionID: UUID?
    @State private var pendingReflectionStatus: String = ""
    @State private var pendingReflectionEssay: String?
    @State private var parentNote: String = "Thanks for being honest."

    @State private var submittedTasks: [DebugTaskRow] = []

    private struct DebugTaskRow: Identifiable {
        let id: UUID
        let title: String
        let phase: String
    }

    private var childUUID: UUID? { UUID(uuidString: childDeviceID) }

    var body: some View {
        NavigationStack {
            Form {
                section_identity
                section_trigger
                section_reflectionApprove
                section_taskReview
                section_status
            }
            .navigationTitle("BigKid debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await refreshKidState() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(working || childUUID == nil)
                }
            }
            .task { await refreshKidState() }
        }
    }

    // MARK: - Sections

    private var section_identity: some View {
        Section("Target child") {
            HStack {
                Text("UUID").font(.system(.body, design: .monospaced))
                Spacer()
                Text(childDeviceID.isEmpty ? "(not paired)" : childDeviceID)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(childUUID == nil ? .red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Text("API root").font(.system(.body, design: .monospaced))
                Spacer()
                Text(apiClient.baseURL)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var section_trigger: some View {
        Section {
            TextField("e.g. \"hit your sister\" or \"stayed up too late\"", text: $reason, axis: .vertical)
                .lineLimit(2...4)
            Button {
                Task { await triggerReflection() }
            } label: {
                Label(working ? "Working…" : "Trigger reflection",
                      systemImage: "sparkles")
            }
            .disabled(working || reason.trimmingCharacters(in: .whitespaces).isEmpty || childUUID == nil)
        } header: {
            Text("1. Trigger reflection")
        } footer: {
            Text("Hits POST /parent/reflection/trigger. If BIGKID_USE_GEMINI=1 on the backend the reason is sent to Gemini, otherwise the seed fixture is returned.")
        }
    }

    @ViewBuilder
    private var section_reflectionApprove: some View {
        Section {
            if let rid = pendingReflectionID {
                LabeledContent("Reflection ID") {
                    Text(rid.uuidString)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                }
                LabeledContent("Status") {
                    Text(pendingReflectionStatus).foregroundStyle(.secondary)
                }
                if let essay = pendingReflectionEssay, !essay.isEmpty {
                    DisclosureGroup("Kid's essay") {
                        Text(essay).font(.system(.callout))
                    }
                }
                TextField("Parent note (optional)", text: $parentNote, axis: .vertical)
                    .lineLimit(1...3)
                Button {
                    Task { await approveReflection(rid: rid) }
                } label: {
                    Label("Approve", systemImage: "checkmark.seal.fill")
                }
                .disabled(working || pendingReflectionStatus != "submitted")
            } else {
                Text("No active reflection.").foregroundStyle(.secondary).font(.callout)
            }
        } header: {
            Text("2. Approve pending reflection")
        } footer: {
            Text("Approve only enables once kid finishes all 3 reflection steps and the request is in `submitted` status. Refresh after the kid submits the essay.")
        }
    }

    @ViewBuilder
    private var section_taskReview: some View {
        Section {
            if submittedTasks.isEmpty {
                Text("No submitted tasks awaiting review.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(submittedTasks) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.title).font(.body)
                        HStack(spacing: 12) {
                            Button("Approve") {
                                Task { await reviewTask(id: row.id, decision: "approve") }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Button("Redo") {
                                Task { await reviewTask(id: row.id, decision: "redo") }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Spacer()
                            Text(row.phase).foregroundStyle(.secondary).font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("3. Review submitted tasks")
        } footer: {
            Text("Tasks the kid submitted photo evidence for. Approve flips status to `done`; Redo bounces back with the redo phase.")
        }
    }

    private var section_status: some View {
        Section("Status") {
            Text(status)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: - Actions

    private func setStatus(_ s: String) { status = s }

    private func triggerReflection() async {
        guard let child = childUUID else { setStatus("✗ child UUID missing"); return }
        working = true; defer { working = false }
        let body = ["child_id": child.uuidString,
                    "reason": reason.trimmingCharacters(in: .whitespaces)]
        do {
            let data = try await postJSON(path: "/parent/reflection/trigger", body: body)
            let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let rid = (dict?["id"] as? String) ?? "?"
            // Use the trigger response directly to populate Section 2 —
            // no need to round-trip through /child/state, which would
            // overwrite this status message with "Refreshed kid state."
            if let idStr = dict?["id"] as? String, let parsed = UUID(uuidString: idStr) {
                pendingReflectionID = parsed
                pendingReflectionStatus = (dict?["status"] as? String) ?? "pending"
                pendingReflectionEssay = nil
            }
            setStatus("✓ Reflection triggered (id=\(rid)). Switch to kid mode and watch State A appear within 60s.")
        } catch {
            setStatus("✗ Trigger failed: \(error)")
        }
    }

    private func approveReflection(rid: UUID) async {
        working = true; defer { working = false }
        let trimmedNote = parentNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = trimmedNote.isEmpty
            ? [:]
            : ["parent_note": trimmedNote]
        do {
            _ = try await postJSON(path: "/parent/reflection/\(rid)/approve", body: body)
            setStatus("✓ Approved \(rid). Kid will route to CompleteScreen on next poll.")
            await refreshKidState()
        } catch {
            setStatus("✗ Approve failed: \(error)")
        }
    }

    private func reviewTask(id: UUID, decision: String) async {
        working = true; defer { working = false }
        var body: [String: Any] = ["decision": decision]
        if decision == "redo" {
            body["redo_reason"] = "Looks like there's still a bit to clean up — try again?"
        }
        do {
            _ = try await postJSON(path: "/parent/task/\(id)/review", body: body)
            setStatus("✓ Task \(id) → \(decision)")
            await refreshKidState()
        } catch {
            setStatus("✗ Review failed: \(error)")
        }
    }

    // MARK: - Refresh

    private func refreshKidState() async {
        guard let child = childUUID else {
            setStatus("✗ child UUID missing — pair first or set evlin.childDeviceID in Settings")
            return
        }
        working = true; defer { working = false }
        do {
            let data = try await getJSON(path: "/child/state", childHeader: child)
            let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            // Reflection
            if let rdict = dict["reflection_request"] as? [String: Any],
               let idStr = rdict["id"] as? String,
               let rid = UUID(uuidString: idStr) {
                pendingReflectionID = rid
                pendingReflectionStatus = (rdict["status"] as? String) ?? ""
                pendingReflectionEssay = rdict["essay_text"] as? String
            } else {
                pendingReflectionID = nil
                pendingReflectionStatus = ""
                pendingReflectionEssay = nil
            }
            // Submitted tasks
            if let tasks = dict["tasks"] as? [[String: Any]] {
                submittedTasks = tasks.compactMap { t -> DebugTaskRow? in
                    guard let idStr = t["id"] as? String,
                          let id = UUID(uuidString: idStr),
                          let title = t["title"] as? String,
                          let status = t["status"] as? String,
                          status == "submitted"
                    else { return nil }
                    let phase = (t["phase"] as? String) ?? "?"
                    return DebugTaskRow(id: id, title: title, phase: phase)
                }
            } else {
                submittedTasks = []
            }
            setStatus("✓ Refreshed kid state.")
        } catch {
            setStatus("✗ Refresh failed: \(error)")
        }
    }

    // MARK: - HTTP helpers

    private func postJSON(path: String, body: [String: Any]) async throws -> Data {
        var req = try makeRequest(path: path, method: "POST", childHeader: nil)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func getJSON(path: String, childHeader: UUID?) async throws -> Data {
        let req = try makeRequest(path: path, method: "GET", childHeader: childHeader)
        return try await send(req)
    }

    private func makeRequest(path: String, method: String, childHeader: UUID?) throws -> URLRequest {
        let base = apiClient.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let url = URL(string: base + path) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        if let child = childHeader {
            req.setValue(child.uuidString, forHTTPHeaderField: "X-Child-Id")
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard 200..<300 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw NSError(domain: "ParentBigKidDebug", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
        }
        return data
    }
}
#endif
