import SwiftUI

/// Used for E4 (no close match — empty variant) and F1 (1 or N close matches).
struct ListSuggestionCard: View {
    let payload: CardPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: payload.icon).font(.title2)
                Text(payload.title).font(.headline)
            }
            if !payload.body.isEmpty {
                Text(payload.body).font(.subheadline).foregroundStyle(.secondary)
            }

            if let existing = payload.itemList, !existing.isEmpty {
                Text("Existing lists:").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(existing, id: \.self) { line in
                        HStack(alignment: .top) {
                            Text("•"); Text(line).font(.subheadline)
                        }
                    }
                }
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
