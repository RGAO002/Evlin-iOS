import SwiftUI

nonisolated struct EvlinV2MasterLockAccessibility: Equatable, Sendable {
    let label: String?
    let enabled: Bool

    static func describe(_ presentation: MasterLockPresentation) -> Self {
        switch presentation {
        case .hiddenForReflection: Self(label: nil, enabled: false)
        case .updating: Self(label: "Updating devices", enabled: false)
        case .lockApps: Self(label: "Lock apps", enabled: true)
        case .unlockDirect, .unlockWithDuration: Self(label: "Unlock apps", enabled: true)
        case .mixed: Self(label: "Some devices are locked", enabled: true)
        case .overrideActive: Self(label: "Lock now", enabled: true)
        case .delivery(let model): Self(label: model.canRetry ? "Retry device update" : "Updating devices", enabled: model.canRetry)
        }
    }
}

struct EvlinV2MasterLockControl: View {
    let presentation: MasterLockPresentation
    let errorMessage: String?
    let onLock: () -> Void
    let onUnlockDirect: () -> Void
    let onUnlockWithDuration: (MasterUnlockSheetModel) -> Void
    let onShowMixed: (MasterLockMixedModel) -> Void
    let onLockNow: () -> Void
    let onRetry: () -> Void

    var body: some View {
        if case .hiddenForReflection = presentation {
            EmptyView()
        } else {
            VStack(spacing: 8) {
                controlButton
                if let status = statusCopy {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: status.icon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(status.text)
                            .font(EvlinV2ProfileTokens.font(11, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(status.color)
                }
                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(EvlinV2ProfileTokens.font(11, weight: .medium))
                        .foregroundStyle(EvlinV2ProfileTokens.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var controlButton: some View {
        switch presentation {
        case .hiddenForReflection:
            EmptyView()
        case .updating:
            button(title: "Updating devices", icon: "arrow.triangle.2.circlepath", tone: .neutral, enabled: false) {}
        case .lockApps:
            button(title: "Lock apps", icon: "lock.fill", tone: .lock, action: onLock)
        case .unlockDirect:
            button(title: "Unlock apps", icon: "lock.open.fill", tone: .unlock, action: onUnlockDirect)
        case .unlockWithDuration(let model):
            button(title: "Unlock apps", icon: "lock.open.fill", tone: .unlock) {
                onUnlockWithDuration(model)
            }
        case .mixed(let model):
            button(title: "Some devices are locked", icon: "rectangle.2.swap", tone: .neutral) {
                onShowMixed(model)
            }
        case .overrideActive:
            button(title: "Lock now", icon: "lock.fill", tone: .lock, action: onLockNow)
        case .delivery(let model):
            button(
                title: model.canRetry ? "Retry device update" : "Updating devices",
                icon: model.canRetry ? "arrow.clockwise" : "arrow.triangle.2.circlepath",
                tone: .neutral,
                enabled: model.canRetry,
                action: onRetry
            )
        }
    }

    private var statusCopy: (icon: String, text: String, color: Color)? {
        switch presentation {
        case .overrideActive(let expiresAt):
            return ("timer", "Unlocked by parent until \(expiresAt.formatted(date: .omitted, time: .shortened))", EvlinV2ProfileTokens.accent)
        case .delivery(let model):
            let waiting = model.waitingDeviceNames + model.unreachableDeviceNames
            if !model.failedDeviceNames.isEmpty {
                return ("exclamationmark.triangle.fill", "Couldn't update \(model.failedDeviceNames.joined(separator: ", ")).", EvlinV2ProfileTokens.danger)
            }
            if !waiting.isEmpty {
                return ("clock", "Waiting for \(waiting.joined(separator: ", ")).", EvlinV2ProfileTokens.textMuted)
            }
            return nil
        default:
            return nil
        }
    }

    private enum Tone { case lock, unlock, neutral }

    private func button(
        title: String,
        icon: String,
        tone: Tone,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        let color: Color = switch tone {
        case .lock: EvlinV2ProfileTokens.accent
        case .unlock: EvlinV2ProfileTokens.danger
        case .neutral: EvlinV2ProfileTokens.primary
        }
        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(EvlinV2ProfileTokens.font(14, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(color))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.62)
        .accessibilityLabel(title)
    }
}
