import SwiftUI

struct DeviceRow: View {
    let iconSystemName: String
    let name: String
    let detail: String
    var locked: Bool = false
    var isLast: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.evSurfaceContainerLow)
                Image(systemName: iconSystemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.custom("Manrope", size: 14).weight(.bold))
                    .foregroundStyle(Color.evPrimary)
                Text(detail)
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            Spacer()

            // Status pill with leading dot
            HStack(spacing: 6) {
                Circle()
                    .fill(locked ? Color.evError : Color.evSecondary)
                    .frame(width: 6, height: 6)
                Text(locked ? "LOCKED" : "ACTIVE")
                    .font(.custom("Inter", size: 9).weight(.heavy))
                    .tracking(1.3)
                    .foregroundStyle(locked ? Color.evError : Color.evSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(locked ? Color.evErrorContainer : Color.evSecondaryContainer)
            )
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .overlay(
            Rectangle().fill(Color.evOutlineVariant.opacity(isLast ? 0 : 0.4))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}
