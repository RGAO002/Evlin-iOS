import SwiftUI

struct EvlinV2MixedLockSheet: View {
    let childName: String
    let model: MasterLockMixedModel
    let onLockAll: () -> Void
    let onUnlockAll: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("\(childName)'s devices do not currently match. Choose the state you want across all enrolled devices.")
                            .font(EvlinV2ProfileTokens.font(14, weight: .medium))
                            .foregroundStyle(EvlinV2ProfileTokens.textMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        deviceGroup(title: "LOCKED", names: model.lockedDeviceNames, icon: "lock.fill")
                        deviceGroup(title: "UNLOCKED", names: model.unlockedDeviceNames, icon: "lock.open.fill")
                    }
                    .padding(20)
                }
                .scrollIndicators(.hidden)

                Divider()

                HStack(spacing: 10) {
                    Button(action: onLockAll) {
                        actionLabel("Lock all", icon: "lock.fill", color: EvlinV2ProfileTokens.accent)
                    }
                    .buttonStyle(.plain)

                    Button(action: onUnlockAll) {
                        actionLabel("Unlock all", icon: "lock.open.fill", color: EvlinV2ProfileTokens.danger)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Button("Cancel", action: onCancel)
                    .font(EvlinV2ProfileTokens.font(14, weight: .semibold))
                    .foregroundStyle(EvlinV2ProfileTokens.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            .navigationTitle("Some devices are locked")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.fraction(0.72)])
        .presentationDragIndicator(.hidden)
        .presentationContentInteraction(.scrolls)
    }

    private func deviceGroup(title: String, names: [String], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(EvlinV2ProfileTokens.font(10, weight: .bold))
                .foregroundStyle(EvlinV2ProfileTokens.textMuted)
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
