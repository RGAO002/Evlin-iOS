import SwiftUI

enum U1ExpiryParser {
    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFractionalSeconds = ISO8601DateFormatter()

    static func date(from iso: String) -> Date? {
        withFractionalSeconds.date(from: iso) ?? withoutFractionalSeconds.date(from: iso)
    }
}

struct U1Card: View {
    let entries: [U1ShieldEntry]
    let verb: String
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
                Text(isUnblock ? "Unblock which one?" : "Unlock which one?")
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
                    Text(isUnblock ? "Unblock selected" : "Unlock selected")
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
                        Text(isUnblock ? "Unblock everything" : "Unlock everything")
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

    private var isUnblock: Bool {
        verb.localizedCaseInsensitiveContains("unblock")
    }

    @ViewBuilder
    private func rowView(entry: U1ShieldEntry) -> some View {
        // Hard disable when an All Apps shield definitionally covers this
        // row — strike the text, dim the icons, ignore taps. The subtitle
        // explains why (see subtitle() below). Soft category-coverage is
        // intentionally NOT disabled: we can't *know* if the app is in
        // the category (Apple API limit), so the parent keeps agency.
        let isHardCovered = entry.coveredByAll
        Button(action: { toggle(entry.index) }) {
            HStack(spacing: 12) {
                Image(systemName: selected.contains(entry.index)
                      ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22))
                    .foregroundStyle(selected.contains(entry.index)
                                     ? Color.evPrimary : Color.evOutline)
                VStack(alignment: .leading, spacing: 2) {
                    shieldName(entry, isHardCovered: isHardCovered)
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
            .opacity(isHardCovered ? 0.45 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isHardCovered)
    }

    @ViewBuilder
    private func shieldName(_ entry: U1ShieldEntry, isHardCovered: Bool) -> some View {
        // Category tokens are opaque and their Apple Label rendering is not
        // reliable in the parent-side unlock picker. Use a deterministic glyph
        // here so category rows never appear blank; token-backed Label rendering
        // remains available in kid-side capture/management surfaces.
        switch entry.kind {
        case "category":
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.evOutline)
                    .frame(width: 24, height: 24)
                Text(NameWithIcon.displayName(entry.displayName))
                    .font(.system(size: 15, weight: .medium))
                    .strikethrough(isHardCovered, color: nil)
            }
        default:
            let kind: NameIconKind = {
                switch entry.kind {
                case "list": return .savedList
                case "all": return .all
                default: return .app
                }
            }()
            NameWithIcon(name: entry.displayName, kind: kind,
                         titleFont: .system(size: 15, weight: .medium),
                         strikethrough: isHardCovered)
        }
    }

    private func toggle(_ idx: Int) {
        if selected.contains(idx) { selected.remove(idx) } else { selected.insert(idx) }
    }

    private func subtitle(for entry: U1ShieldEntry) -> String {
        U1SubtitleFormatter.subtitle(for: entry)
    }
}

enum U1SubtitleFormatter {
    static func subtitle(for entry: U1ShieldEntry) -> String {
        if entry.coveredByAll {
            return "Covered by All Apps shield"
        }
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
            guard let iso = entry.expiresAtISO else {
                return "Permanent — manual unlock only"
            }
            guard let date = U1ExpiryParser.date(from: iso) else {
                return "Permanent — manual unlock only"
            }
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return "Unlocks \(f.string(from: date))"
        }()
        let prefix = entry.stale ? "May be stale · " : ""
        let base = "\(prefix)\(kindLabel) · \(expiry)"
        // Soft category warning: backend tells us "an Entertainment shield
        // is active" but Apple doesn't let us check whether Instagram is
        // in Entertainment. Surface every active category so the parent
        // sees the possibility — if they tap and iOS reports nothing-to-
        // unshield, Phase 1b's follow-up card will offer to also unlock
        // the category.
        let warnings = entry.categoryWarnings
        guard !warnings.isEmpty else { return base }
        let joined = ListFormatter.localizedString(byJoining: warnings)
        return "\(base) · May still be covered by \(joined)"
    }
}

#if DEBUG
// Phase 1b preview: exercises every coverage state so the rendering
// stays visually verifiable without booting backend.
//   - All Apps row: stays normal (it's the broader shield itself).
//   - Entertainment (category): stays normal in this preview (no All
//     Apps disables it; would be disabled if an "all" row were added).
//   - Instagram (app): soft-warned by Entertainment + Social — tappable,
//     subtitle shows "May still be covered by Entertainment and Social".
//   - Spotify (app, also app-tier): same soft warning.
//   - The example below shows a different scenario — All Apps active +
//     Instagram. Comment out one branch when previewing the other.
#Preview("All Apps overrides everything") {
    U1Card(
        entries: [
            U1ShieldEntry(index: 0, kind: "all", displayName: "All Apps",
                          expiresAtISO: nil, stale: false),
            U1ShieldEntry(index: 1, kind: "category", displayName: "Entertainment",
                          expiresAtISO: nil, stale: false,
                          coveredByAll: true, categoryWarnings: []),
            U1ShieldEntry(index: 2, kind: "app", displayName: "Instagram",
                          expiresAtISO: "2026-05-07T16:19:00Z", stale: false,
                          coveredByAll: true, categoryWarnings: []),
        ],
        verb: "unlock",
        onUnlockSelected: { print("selected: \($0)") },
        onUnlockEverything: { print("everything") },
        onCancel: { print("cancel") }
    )
    .padding()
}

#Preview("Category + app — soft warning") {
    U1Card(
        entries: [
            U1ShieldEntry(index: 0, kind: "category", displayName: "Entertainment",
                          expiresAtISO: nil, stale: false),
            U1ShieldEntry(index: 1, kind: "category", displayName: "Social",
                          expiresAtISO: nil, stale: false),
            U1ShieldEntry(index: 2, kind: "app", displayName: "Instagram",
                          expiresAtISO: "2026-05-07T16:19:00Z", stale: false,
                          categoryWarnings: ["Entertainment", "Social"]),
            U1ShieldEntry(index: 3, kind: "list", displayName: "Bedtime apps",
                          expiresAtISO: "2026-05-07T22:00:00Z", stale: true),
        ],
        verb: "unlock",
        onUnlockSelected: { print("selected: \($0)") },
        onUnlockEverything: { print("everything") },
        onCancel: { print("cancel") }
    )
    .padding()
}
#endif
