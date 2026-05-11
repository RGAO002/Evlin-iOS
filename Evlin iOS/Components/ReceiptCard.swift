import SwiftUI

enum ReceiptState: Sendable, Equatable, Codable {
    case pending
    /// Mirrors AckResult.confirmedExact. `verb` drives copy branching so
    /// `unblock Instagram` renders as "Unblocked Instagram", not "Shielded Instagram".
    case confirmedExact(verb: AckVerb, displayName: String, unlocksAt: Date?)
    case confirmedFallback(verb: AckVerb, displayName: String, category: String, origRequest: String)
    case failedPermission
    case failedListNotFound(listName: String)
    case failedCategoryNotConfigured(category: String)
    case failedAppNotConfigured(appReference: String)
    case failedTimeout
    /// Kid device hasn't acked within the local deadline. Distinct from
    /// `failedTimeout` (which is a real backend timeout): the command is
    /// still queued server-side and will run when the kid comes back —
    /// we just stopped polling so the parent isn't staring at a spinner.
    case kidNotResponding
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
                // The command sits in the backend queue until the kid
                // device polls and applies it. On a real two-device
                // setup that's seconds. In single-device dev it's
                // however long it takes to flip P→K — 'Sending…' read
                // as a network failure when actually the request was
                // accepted and is waiting on the kid.
                Text("Queued — waiting for kid device").font(.subheadline)
            }
        case .confirmedExact(let verb, let name, let unlocksAt):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    NameWithIcon(name: name, kind: .app, titleFont: .subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: iconForVerb(verb))
                }
                if verb == .shield {
                    if let at = unlocksAt {
                        Text("Unlocks at \(timeString(at))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Until you unlock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .confirmedFallback(_, let name, let category, let orig):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    NameWithIcon(name: name, kind: .app, titleFont: .subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "arrow.triangle.branch")
                }
                Text("No exact match for \(orig); applied to \(category) instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .failedPermission:
            Label("Screen Time permission required.", systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(.red)
        case .failedListNotFound(let listName):
            Label("List \"\(listName)\" not found.", systemImage: "xmark.octagon")
                .font(.subheadline).foregroundStyle(.red)
        case .failedCategoryNotConfigured(let cat):
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon").foregroundStyle(.red)
                Text("Category ").font(.subheadline).foregroundStyle(.red)
                NameWithIcon(name: cat, kind: .category, titleFont: .subheadline)
                Text(" not configured.").font(.subheadline).foregroundStyle(.red)
            }
        case .failedAppNotConfigured(let ref):
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon").foregroundStyle(.red)
                Text("App ").font(.subheadline).foregroundStyle(.red)
                NameWithIcon(name: ref, kind: .app, titleFont: .subheadline)
                Text(" not found in Managed Apps.").font(.subheadline).foregroundStyle(.red)
            }
        case .failedTimeout:
            Label("Command timed out.", systemImage: "clock")
                .font(.subheadline).foregroundStyle(.red)
        case .kidNotResponding:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kid's phone hasn't responded yet")
                        .font(.subheadline).fontWeight(.medium)
                        .foregroundStyle(.orange)
                    Text("Still queued — will apply when Evlin opens on their device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
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
            let shown = NameWithIcon.displayName(strongest.displayName)
            if let exp = strongestExpires {
                return "Still shielded by \(shown) until \(timeString(exp))."
            }
            return "Still shielded by \(shown) permanently."
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
