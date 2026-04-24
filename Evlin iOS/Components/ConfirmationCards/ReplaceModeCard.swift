import SwiftUI

/// Used for B1 (Permanent→timed), B2 (Block→shield), C1 (Shield→block), C2 (Block in shielded list).
struct ReplaceModeCard: View {
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
                            .background(btn.style == .primary ? Color.accentColor
                                         : btn.style == .destructive ? Color.red
                                         : Color(.systemGray5))
                            .foregroundColor(btn.style == .primary || btn.style == .destructive ? .white : .primary)
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
}
