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
            EvlinPill(
                text: locked ? "Locked" : "Active",
                tone: locked ? .danger : .success,
                size: .xs
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
