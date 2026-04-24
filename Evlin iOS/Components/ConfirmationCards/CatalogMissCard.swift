import SwiftUI

/// Used for E3 — block attempted on unrecognized app.
struct CatalogMissCard: View {
    let payload: CardPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.title2)
                Text(payload.title).font(.headline)
            }
            Text(payload.body).font(.subheadline).foregroundStyle(.secondary)

            if let bullets = payload.itemList {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(bullets, id: \.self) { line in
                        HStack(alignment: .top) {
                            Text("•").font(.subheadline).foregroundStyle(.secondary)
                            Text(line).font(.subheadline).foregroundStyle(.secondary)
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
