import SwiftUI

enum ReceiptState: Sendable, Equatable {
    case pending
    /// Mirrors AckResult.confirmedExact. `verb` drives copy branching so
    /// `unblock Instagram` renders as "Unblocked Instagram", not "Shielded Instagram".
    case confirmedExact(verb: AckVerb, displayName: String, unlocksAt: Date?)
    case confirmedFallback(verb: AckVerb, displayName: String, category: String, origRequest: String)
    case failedPermission
    case failedListNotFound(listName: String)
    case failedCategoryNotConfigured(category: String)
    case failedTimeout
    case failedOther(reason: String)
}

/// Two-line receipt: primary mutation + optional effective-state disclosure.
/// See spec §8.
///
/// IMPORTANT: ReceiptCard runs on the PARENT device. The child computes
/// AckEffectiveState and ships it up through the ack → ack-status endpoints.
/// Parent never queries its own ActiveLockStore here.
struct ReceiptCard: View {
    let state: ReceiptState
    let effectiveState: AckEffectiveState?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            primaryLine
            if let line = effectiveStateLine {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var primaryLine: some View {
        switch state {
        case .pending:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Sending…").font(.subheadline)
            }
        case .confirmedExact(let verb, let name, let unlocksAt):
            HStack(spacing: 8) {
                Image(systemName: iconForVerb(verb))
                VStack(alignment: .leading) {
                    Text(titleForVerb(verb, displayName: name))
                        .font(.subheadline).fontWeight(.medium)
                    if verb == .shield {
                        if let at = unlocksAt {
                            Text("Unlocks at \(timeString(at))").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Until you unlock").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        case .confirmedFallback(let verb, _, let category, let orig):
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                VStack(alignment: .leading) {
                    Text(fallbackTitleForVerb(verb, category: category))
                        .font(.subheadline).fontWeight(.medium)
                    Text("No exact match for \(orig); applied to \(category) instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .failedPermission:
            Label("Screen Time permission required.", systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(.red)
        case .failedListNotFound(let listName):
            Label("List \"\(listName)\" not found.", systemImage: "xmark.octagon")
                .font(.subheadline).foregroundStyle(.red)
        case .failedCategoryNotConfigured(let cat):
            Label("Category \(cat) not configured.", systemImage: "xmark.octagon")
                .font(.subheadline).foregroundStyle(.red)
        case .failedTimeout:
            Label("Command timed out.", systemImage: "clock")
                .font(.subheadline).foregroundStyle(.red)
        case .failedOther(let reason):
            Label(reason, systemImage: "xmark.octagon").font(.subheadline).foregroundStyle(.red)
        }
    }

    /// Effective-state line per spec §8.3 — honest about indeterminate coverage.
    private var effectiveStateLine: String? {
        guard let effectiveState = effectiveState else { return nil }
        if effectiveState.isBlocked { return "Still blocked." }

        if !effectiveState.shieldsCovering.isEmpty {
            let iso = ISO8601DateFormatter()
            let parsed: [(AckEffectiveState.ShieldCover, Date?)] = effectiveState.shieldsCovering.map {
                ($0, $0.expiresAtISO.flatMap { iso.date(from: $0) })
            }
            let sorted = parsed.sorted { a, b in
                if a.1 == nil && b.1 != nil { return true }
                if a.1 != nil && b.1 == nil { return false }
                return (a.1 ?? .distantPast) > (b.1 ?? .distantPast)
            }
            let (strongest, strongestExpires) = sorted[0]
            if let exp = strongestExpires {
                return "Still shielded by \(strongest.displayName) until \(timeString(exp))."
            }
            return "Still shielded by \(strongest.displayName) permanently."
        }

        if effectiveState.possibleSavedListCoverage {
            return "May still be covered by a Saved List — check Settings."
        }

        return nil
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: - Verb-driven copy helpers

    private func iconForVerb(_ verb: AckVerb) -> String {
        switch verb {
        case .shield:      return "checkmark.shield"
        case .block:       return "eye.slash"
        case .unshield:    return "lock.open"
        case .unblock:     return "eye"
        case .unshieldAll: return "lock.open.rotation"
        case .unblockAll:  return "eye.circle"
        }
    }

    private func titleForVerb(_ verb: AckVerb, displayName: String) -> String {
        switch verb {
        case .shield:      return "Shielded \(displayName)"
        case .block:       return "Hidden \(displayName) from home screen"
        case .unshield:    return "Unshielded \(displayName)"
        case .unblock:     return "Restored \(displayName) to home screen"
        case .unshieldAll: return "All shields cleared (\(displayName))"
        case .unblockAll:  return "All blocks cleared (\(displayName))"
        }
    }

    private func fallbackTitleForVerb(_ verb: AckVerb, category: String) -> String {
        switch verb {
        case .shield:      return "\(category.capitalized) shielded (fallback)"
        case .unshield:    return "\(category.capitalized) unshielded (fallback)"
        default:           return "\(category.capitalized) updated (fallback)"
        }
    }
}
