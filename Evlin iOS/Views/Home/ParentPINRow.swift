import Foundation

struct ParentPINRowDisplay: Equatable {
    let title: String
    let subtitle: String
    let value: String?
    let canClear: Bool
}

enum ParentPINRow {
    static func display(status: String, pin: String?, kidName: String) -> ParentPINRowDisplay {
        let trimmed = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = trimmed.isEmpty ? "your child" : trimmed
        switch status {
        case "available":
            guard let pin, !pin.isEmpty else {
                return ParentPINRowDisplay(
                    title: "Parent PIN",
                    subtitle: "Will appear when \(who)'s phone syncs.",
                    value: nil,
                    canClear: true
                )
            }
            return ParentPINRowDisplay(
                title: "Parent PIN",
                subtitle: "Set on \(who)'s phone.",
                value: pin,
                canClear: true
            )
        case "pending_sync":
            return ParentPINRowDisplay(
                title: "Parent PIN",
                subtitle: "Will appear when \(who)'s phone syncs.",
                value: nil,
                canClear: true
            )
        case "unrecoverable":
            return ParentPINRowDisplay(
                title: "Parent PIN unavailable",
                subtitle: "Clear it here, then create a new PIN on \(who)'s phone.",
                value: nil,
                canClear: true
            )
        default:
            return ParentPINRowDisplay(
                title: "Parent PIN not set",
                subtitle: "Create it in Parent Controls on \(who)'s phone.",
                value: nil,
                canClear: false
            )
        }
    }
}
