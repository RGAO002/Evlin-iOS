import SwiftUI
import Combine

/// Receipt for an agent-executed action. Shows summary + Undo button
/// with a wall-clock-driven countdown derived from `receipt.undoExpiresAt`
/// (server-supplied ISO8601 deadline). Tapping Undo POSTs
/// /parent/actions/{id}/revert.
struct ReceiptBubble: View {
    let receipt: ReceiptDTO
    var onUndo: (String) async -> Void
    @State private var secondsRemaining: Int = 0
    @State private var undoing = false
    @State private var undoneByUser = false
    @State private var timerCancellable: Cancellable? = nil

    /// True when there's no token, or the wall-clock deadline has passed,
    /// or the user already pressed Undo. Used to grey out the button.
    private var isFinal: Bool {
        undoneByUser || secondsRemaining <= 0 || receipt.undoToken == nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.evSecondary)
                .font(.system(size: 18, weight: .semibold))
            Text(receipt.summary)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.evOnSurface)
            Spacer(minLength: 0)
            if let token = receipt.undoToken, !isFinal {
                Button(action: { Task { await runUndo(token: token) } }) {
                    Text(undoing ? "…" : "Undo (\(secondsRemaining))")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Color.evError)
                }
                .disabled(undoing)
            } else if receipt.undoToken != nil {
                Text(undoneByUser ? "Done" : "Expired")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.gray)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.evSurfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            // Recompute remaining seconds from the server-supplied wall-clock
            // deadline every time the view appears (e.g. user navigates back
            // to the chat tab). Without this, secondsRemaining was reset to
            // 60 on every onAppear, lying about Undo validity.
            secondsRemaining = receipt.undoSecondsRemaining
            if secondsRemaining <= 0 { return }
            let publisher = Timer.publish(every: 1, on: .main, in: .common)
            timerCancellable = publisher.autoconnect().sink { _ in
                let live = receipt.undoSecondsRemaining
                secondsRemaining = live
                if live <= 0 {
                    timerCancellable?.cancel()
                    timerCancellable = nil
                }
            }
        }
        .onDisappear {
            timerCancellable?.cancel()
            timerCancellable = nil
        }
    }

    private func runUndo(token: String) async {
        undoing = true
        await onUndo(token)
        undoing = false
        undoneByUser = true
    }
}
