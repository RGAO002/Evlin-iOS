import SwiftUI

/// Plan 5 — owner-side co-parent management, presented from Settings ("App
/// Controls → Co-parents"). The OWNER mints + shares a co-parent invite,
/// approves/declines pending consumers (owner-approval is ON), and revokes
/// unused invites. Talks to the live `/family/invite*` endpoints through the
/// authed `APIClient` invite methods.
///
/// Owner-only by contract: a non-owner who opens this hits 403 `not_owner` on
/// mint and sees an inline message. The list itself is family-scoped (👪), so
/// any bound member can read it, but only the owner's actions succeed.
struct OwnerInviteApprovalView: View {
    @EnvironmentObject var apiClient: APIClient

    @State private var invites: [InviteSummaryDTO] = []
    @State private var lastShareText: String?
    @State private var errorText: String?
    @State private var isWorking = false
    @State private var loaded = false

    var body: some View {
        Form {
            if let errorText {
                Section {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Invite a co-parent") {
                Button {
                    Task { await mint() }
                } label: {
                    Label(isWorking ? "Creating…" : "Create invite code",
                          systemImage: "person.badge.plus")
                }
                .disabled(isWorking)

                if let lastShareText {
                    Text(lastShareText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ShareLink(item: lastShareText) {
                        Label("Share invite", systemImage: "square.and.arrow.up")
                    }
                }

                Text("Invites expire in 7 days. You can have up to 3 active at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Invites") {
                if invites.isEmpty {
                    Text(loaded ? "No invites yet." : "Loading…")
                        .foregroundStyle(.secondary)
                }
                ForEach(invites) { inv in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(inv.code)
                            .font(.body.monospaced())
                        Text(statusLabel(inv))
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if inv.approvalStatus == "pending" {
                            HStack(spacing: 12) {
                                Button("Approve") {
                                    Task { await decide(inv.code, "approve") }
                                }
                                .buttonStyle(.borderedProminent)
                                Button("Decline", role: .destructive) {
                                    Task { await decide(inv.code, "decline") }
                                }
                                .buttonStyle(.bordered)
                            }
                        } else if inv.consumedAt == nil {
                            Button("Revoke", role: .destructive) {
                                Task { await revoke(inv.code) }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Co-parents")
        .task {
            await reload()
            loaded = true
        }
        .refreshable { await reload() }
    }

    private func statusLabel(_ inv: InviteSummaryDTO) -> String {
        switch inv.approvalStatus {
        case "pending":  return "Waiting for your approval"
        case "approved": return "Approved — joined your family"
        case "declined": return "Declined"
        default:         return inv.consumedAt == nil ? "Active (unused)" : "Used"
        }
    }

    private func reload() async {
        invites = (try? await apiClient.listInvites()) ?? []
    }

    private func mint() async {
        errorText = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let dto = try await apiClient.mintInvite()
            lastShareText = dto.shareText
            await reload()
        } catch CoParentInviteError.capReached {
            errorText = "You can have at most 3 active invites. Revoke one first."
        } catch CoParentInviteError.notOwner {
            errorText = "Only the family owner can create invites."
        } catch {
            errorText = "Couldn't create an invite. Try again."
        }
    }

    private func decide(_ code: String, _ decision: String) async {
        errorText = nil
        do {
            _ = try await apiClient.approveInvite(code: code, decision: decision)
        } catch CoParentInviteError.notOwner {
            errorText = "Only the family owner can approve co-parents."
        } catch CoParentInviteError.notPending {
            errorText = "That invite is no longer pending."
        } catch {
            errorText = "Couldn't update that invite. Try again."
        }
        await reload()
    }

    private func revoke(_ code: String) async {
        errorText = nil
        do {
            try await apiClient.revokeInvite(code: code)
        } catch CoParentInviteError.notOwner {
            errorText = "Only the family owner can revoke invites."
        } catch {
            errorText = "Couldn't revoke that invite. Try again."
        }
        await reload()
    }
}
