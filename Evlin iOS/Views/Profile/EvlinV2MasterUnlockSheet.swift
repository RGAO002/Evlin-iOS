import SwiftUI

struct EvlinV2MasterUnlockSheet: View {
    let childName: String
    let model: MasterUnlockSheetModel
    let usageTodayMinutes: Int
    let onConfirm: (MasterUnlockDuration) -> Void
    let onCancel: () -> Void

    @State private var selected: MasterUnlockDuration = .minutes(15)

    private let options: [MasterUnlockDuration] = [
        .minutes(15), .minutes(30), .minutes(60), .untilTomorrow,
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Choose how long \(childName)'s apps stay unlocked. Screen time still counts toward today's pool.")
                        .font(EvlinV2ProfileTokens.font(14, weight: .medium))
                        .foregroundStyle(EvlinV2ProfileTokens.textMuted)

                    HStack(spacing: 10) {
                        Image(systemName: "clock.fill").foregroundStyle(EvlinV2ProfileTokens.accent)
                        Text("\(format(usageTodayMinutes)) used today")
                            .font(EvlinV2ProfileTokens.font(15, weight: .bold))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(EvlinV2ProfileTokens.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Text("UNLOCK FOR")
                        .font(EvlinV2ProfileTokens.font(11, weight: .bold))
                        .foregroundStyle(EvlinV2ProfileTokens.textMuted)

                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 9) {
                        ForEach(options, id: \.label) { option in
                            Button {
                                selected = option
                            } label: {
                                Text(option.label)
                                    .font(EvlinV2ProfileTokens.font(13, weight: .bold))
                                    .foregroundStyle(selected == option ? .white : EvlinV2ProfileTokens.primary)
                                    .frame(maxWidth: .infinity, minHeight: 46)
                                    .background(selected == option ? EvlinV2ProfileTokens.primary : EvlinV2ProfileTokens.surface)
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(EvlinV2ProfileTokens.outline))
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    restrictionSummary
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                actionButtons
            }
            .navigationTitle("Unlock \(childName)'s apps?")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
    }

    private var actionButtons: some View {
        VStack(spacing: 8) {
            Button {
                onConfirm(selected)
            } label: {
                Text("Unlock for \(selected.label)")
                    .font(EvlinV2ProfileTokens.font(15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(RoundedRectangle(cornerRadius: 14).fill(EvlinV2ProfileTokens.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Unlock apps for \(selected.label)")

            Button("Cancel", action: onCancel)
                .font(EvlinV2ProfileTokens.font(14, weight: .semibold))
                .foregroundStyle(EvlinV2ProfileTokens.textMuted)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(EvlinV2ProfileTokens.surface)
    }

    private var restrictionSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.devices, id: \.deviceID) { device in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "iphone").foregroundStyle(EvlinV2ProfileTokens.textMuted)
                    Text(summary(for: device))
                        .font(EvlinV2ProfileTokens.font(12, weight: .medium))
                        .foregroundStyle(EvlinV2ProfileTokens.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(EvlinV2ProfileTokens.danger.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func summary(for device: MasterUnlockDeviceModel) -> String {
        var reasons: [String] = []
        if device.taskIncomplete { reasons.append("unfinished tasks") }
        if device.earnedExhausted { reasons.append("today's pool is used") }
        if device.deviceLimitActive { reasons.append("device limit") }
        if !device.limitedAppIDs.isEmpty || !device.limitedLegacyScopeIDs.isEmpty { reasons.append("app limits") }
        if device.manualAllApps { reasons.append("manual lock") }
        return reasons.isEmpty
            ? "\(device.deviceName) will be unlocked."
            : "\(device.deviceName): temporarily overrides \(reasons.joined(separator: ", "))."
    }

    private func format(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

private extension MasterUnlockDuration {
    var label: String {
        switch self {
        case .minutes(let minutes): "\(minutes) min"
        case .untilTomorrow: "Until tomorrow"
        }
    }
}
