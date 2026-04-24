import SwiftUI

/// Used for A1 (Block first-time) and D3 (long duration).
/// (A2 was removed — single unblock is a direct action with no card.)
struct DangerConfirmCard: View {
    let payload: CardPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: payload.icon).font(.title2)
                Text(payload.title).font(.headline)
            }
            Text(payload.body).font(.subheadline).foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(payload.buttons) { btn in
                    Button(action: btn.action) {
                        Text(btn.label)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(backgroundColor(for: btn.style))
                            .foregroundColor(foregroundColor(for: btn.style))
                            .cornerRadius(10)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 6)
    }

    private func backgroundColor(for style: CardButton.Style) -> Color {
        switch style {
        case .primary: return .accentColor
        case .destructive: return .red
        case .secondary: return Color(.systemGray5)
        case .tertiary: return .clear
        case .cancel: return Color(.systemGray6)
        }
    }
    private func foregroundColor(for style: CardButton.Style) -> Color {
        switch style {
        case .primary, .destructive: return .white
        default: return .primary
        }
    }
}
