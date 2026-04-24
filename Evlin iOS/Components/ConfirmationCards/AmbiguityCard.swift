import SwiftUI

/// Used for D2 — 2-way radio choice.
struct AmbiguityCard: View {
    let payload: CardPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(payload.title).font(.headline)
            if !payload.body.isEmpty {
                Text(payload.body).font(.subheadline).foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(payload.buttons) { btn in
                    Button(action: btn.action) {
                        Text(btn.label)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(btn.style == .primary ? Color.accentColor : Color(.systemGray5))
                            .foregroundColor(btn.style == .primary ? .white : .primary)
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
