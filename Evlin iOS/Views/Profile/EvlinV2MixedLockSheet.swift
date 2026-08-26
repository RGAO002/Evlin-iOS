import SwiftUI

struct EvlinV2MixedLockSheet: View {
    let childName: String
    let model: MasterLockMixedModel
    let onLockAll: () -> Void
    let onUnlockAll: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("\(childName)'s devices do not currently match. Choose the state you want across all enrolled devices.")
                    .font(EvlinV2ProfileTokens.font(14, weight: .medium))
                    .foregroundStyle(EvlinV2ProfileTokens.textMuted)

                deviceGroup(title: "LOCKED", names: model.lockedDeviceNames, icon: "lock.fill")
                deviceGroup(title: "UNLOCKED", names: model.unlockedDeviceNames, icon: "lock.open.fill")

                Button(action: onLockAll) {
                    actionLabel("Lock apps across devices", icon: "lock.fill", color: EvlinV2ProfileTokens.accent)
                }
                .buttonStyle(.plain)

                Button(action: onUnlockAll) {
                    actionLabel("Unlock apps across devices", icon: "lock.open.fill", color: EvlinV2ProfileTokens.danger)
                }
                .buttonStyle(.plain)

                Button("Cancel", action: onCancel)
                    .font(EvlinV2ProfileTokens.font(14, weight: .semibold))
                    .foregroundStyle(EvlinV2ProfileTokens.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 44)
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Some devices are locked")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private func deviceGroup(title: String, names: [String], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(EvlinV2ProfileTokens.font(10, weight: .bold)).foregroundStyle(EvlinV2ProfileTokens.textMuted)
            Label(names.isEmpty ? "None" : names.joined(separator: ", "), systemImage: icon)
                .font(EvlinV2ProfileTokens.font(13, weight: .semibold))
                .foregroundStyle(EvlinV2ProfileTokens.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(EvlinV2ProfileTokens.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func actionLabel(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(EvlinV2ProfileTokens.font(14, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 14).fill(color))
    }
}
