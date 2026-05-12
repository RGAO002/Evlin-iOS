import SwiftUI

struct U1Card: View {
    let entries: [U1ShieldEntry]
    let onUnlockSelected: ([Int]) -> Void
    let onUnlockEverything: () -> Void
    let onCancel: () -> Void

    @State private var selected: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.open")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
                Text("Unlock which one?")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.evOnSurface)
            }
            VStack(spacing: 6) {
                ForEach(entries) { entry in
                    rowView(entry: entry)
                }
            }
            VStack(spacing: 8) {
                Button(action: { onUnlockSelected(Array(selected).sorted()) }) {
                    Text("Unlock selected")
                        .font(.system(size: 15, weight: .heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(selected.isEmpty ? Color.evOutline : Color.evPrimary)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(selected.isEmpty)

                // "Unlock everything" is redundant for a single-shield card —
                // there's only one thing to unlock, so "selected" and
                // "everything" mean the same thing. Worse, the backend's
                // single-shield card factory doesn't emit a target.kind=="all"
                // option, so the handler that maps "everything" to that
                // option becomes a no-op (it taps and nothing happens).
                // Hide the button when there's nothing to disambiguate.
                if entries.count > 1 {
                    Button(action: onUnlockEverything) {
                        Text("Unlock everything")
                            .font(.system(size: 15, weight: .heavy))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color.evSurfaceContainerLow)
                            .foregroundStyle(Color.evError)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.evOutline)
                }
            }
        }
        .padding(16)
        .background(Color.evSurfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.evOutline.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func rowView(entry: U1ShieldEntry) -> some View {
        let kind: NameIconKind = {
            switch entry.kind {
            case "category": return .category
            case "list": return .savedList
            case "all": return .all
            default: return .app
            }
        }()
        Button(action: { toggle(entry.index) }) {
            HStack(spacing: 12) {
                Image(systemName: selected.contains(entry.index)
                      ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22))
                    .foregroundStyle(selected.contains(entry.index)
                                     ? Color.evPrimary : Color.evOutline)
                VStack(alignment: .leading, spacing: 2) {
                    NameWithIcon(name: entry.displayName, kind: kind,
                                 titleFont: .system(size: 15, weight: .medium))
                    Text(subtitle(for: entry))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 32)
                }
                Spacer()
            }
            .padding(8)
            .background(Color.evSurfaceContainerLow)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ idx: Int) {
        if selected.contains(idx) { selected.remove(idx) } else { selected.insert(idx) }
    }

    private func subtitle(for entry: U1ShieldEntry) -> String {
        let kindLabel: String = {
            switch entry.kind {
            case "app": return "App"
            case "category": return "Category"
            case "list": return "List"
            case "all": return "Whole phone"
            default: return entry.kind.capitalized
            }
        }()
        // Expiry copy options:
        //   - has expiresAtISO       → "Unlocks 1:28 AM"
        //   - no expiry (permanent)  → "Permanent — manual unlock only"
        // The previous fallback "Until you unlock" was ambiguous — it
        // suggested an actual time would resolve later, but for permanent
        // shields none ever will. Make the permanence explicit.
        let expiry: String = {
            guard let iso = entry.expiresAtISO,
                  let date = ISO8601DateFormatter().date(from: iso)
            else { return "Permanent — manual unlock only" }
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return "Unlocks \(f.string(from: date))"
        }()
        let prefix = entry.stale ? "May be stale · " : ""
        return "\(prefix)\(kindLabel) · \(expiry)"
    }
}

#if DEBUG
#Preview {
    U1Card(
        entries: [
            U1ShieldEntry(index: 0, kind: "app", displayName: "Instagram",
                          expiresAtISO: "2026-05-07T16:19:00Z", stale: false),
            U1ShieldEntry(index: 1, kind: "category", displayName: "Entertainment",
                          expiresAtISO: nil, stale: false),
            U1ShieldEntry(index: 2, kind: "list", displayName: "Bedtime apps",
                          expiresAtISO: "2026-05-07T22:00:00Z", stale: true),
        ],
        onUnlockSelected: { print("selected: \($0)") },
        onUnlockEverything: { print("everything") },
        onCancel: { print("cancel") }
    )
    .padding()
}
#endif
