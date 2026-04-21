import SwiftUI

struct RuleRow: View {
    enum Tone { case primary, tertiary, neutral }

    let iconSystemName: String
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var tone: Tone = .primary

    private var iconBg: Color {
        switch tone {
        case .primary: return .evPrimaryContainer
        case .tertiary: return .evTertiaryContainer
        case .neutral: return .evSurfaceContainerHigh
        }
    }
    private var iconFg: Color {
        switch tone {
        case .primary: return .evPrimary
        case .tertiary: return .evOnTertiaryContainer
        case .neutral: return .evOnSurfaceVariant
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(iconBg)
                Image(systemName: iconSystemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconFg)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.custom("Manrope", size: 14).weight(.heavy))
                    .foregroundStyle(Color.evPrimary)
                Text(detail)
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Color.evSecondary)
        }
        .padding(.vertical, 10)
    }
}
