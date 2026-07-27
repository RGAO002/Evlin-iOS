import SwiftUI

/// One line of a multi-device app-control receipt.
///
/// The backend authors every string here — the device label, the target, and
/// especially the message, which comes from an allow-list precisely so no
/// internal code (`shield_token_missing`, `lock_store_unavailable`) can reach a
/// parent. The client's job is to render what it was given and to fail toward
/// caution when it cannot.
struct AppControlBatchReceiptRow: Identifiable, Equatable {

    /// The REQUEST's outcome, never the device's. `queued` means the command
    /// committed and delivery was scheduled; whether the device applied it is a
    /// later, separate signal.
    enum Status: String, Equatable {
        case queued
        case failed

        /// Anything unreadable is `failed`. Showing an unknown state as success
        /// is the one direction a parent cannot recover from — they would stop
        /// looking.
        init(wire: String?) {
            self = Status(rawValue: wire ?? "") ?? .failed
        }

        var iconName: String {
            switch self {
            case .queued: return "checkmark.circle.fill"
            case .failed: return "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .queued: return .evSecondary   // the palette's success / unlocked green
            case .failed: return .evError
            }
        }
    }

    let deviceId: String
    let deviceLabel: String
    let targetLabel: String
    let status: Status
    let message: String

    var id: String { deviceId }

    /// Never blank, and never a code. An empty message means the backend sent
    /// something we did not expect; the generic line is still true.
    var displayMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (status == .queued ? "Command sent" : "Couldn't send this command")
            : message
    }

    /// Rows straight off the wire, in the order the backend sent them — that
    /// order is the device picker's, which is the parent's mental model of
    /// their own devices.
    ///
    /// A row missing its identity is dropped rather than rendered blank: a line
    /// that names no device tells a parent nothing and invites them to assume
    /// the wrong one.
    static func decode(_ raw: [[String: Any]]) -> [AppControlBatchReceiptRow] {
        raw.compactMap { entry in
            guard
                let deviceId = entry["device_id"] as? String, !deviceId.isEmpty,
                let deviceLabel = entry["device_label"] as? String, !deviceLabel.isEmpty
            else { return nil }
            return AppControlBatchReceiptRow(
                deviceId: deviceId,
                deviceLabel: deviceLabel,
                targetLabel: entry["target_label"] as? String ?? "",
                status: Status(wire: entry["status"] as? String),
                message: entry["message"] as? String ?? ""
            )
        }
    }
}
