import SwiftUI

/// Used for D1 (quick-pick duration) and D4 (multi-child picker with checkboxes).
struct MissingInfoCard: View {
    let payload: CardPayload
    @State private var checkboxes: [CardCheckboxItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(payload.title).font(.headline)
            if !payload.body.isEmpty {
                Text(payload.body).font(.subheadline).foregroundStyle(.secondary)
            }

            if !checkboxes.isEmpty {
                VStack(spacing: 6) {
                    ForEach($checkboxes) { $item in
                        HStack {
                            Button(action: { item.isSelected.toggle() }) {
                                Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                                    .foregroundColor(item.isSelected ? .accentColor : .secondary)
                            }
                            VStack(alignment: .leading) {
                                Text(item.label).font(.subheadline)
                                if let sub = item.sublabel { Text(sub).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
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
        .onAppear {
            if let items = payload.checkboxes { checkboxes = items }
        }
    }
}
