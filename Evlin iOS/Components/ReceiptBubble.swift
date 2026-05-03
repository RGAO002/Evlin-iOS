import SwiftUI
import Combine

/// Receipt for an agent-executed action. Shows summary + Undo button
/// with 60s countdown. Tapping Undo POSTs /parent/actions/{id}/revert.
struct ReceiptBubble: View {
    let receipt: ReceiptDTO
    var onUndo: (String) async -> Void
    @State private var secondsRemaining: Int = 60
    @State private var undoing = false
    @State private var undoneOrExpired = false
    @State private var timerCancellable: Cancellable? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.evSecondary)
                .font(.system(size: 18, weight: .semibold))
            Text(receipt.summary)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.evOnSurface)
            Spacer(minLength: 0)
            if let token = receipt.undoToken, !undoneOrExpired {
                Button(action: { Task { await runUndo(token: token) } }) {
                    Text(undoing ? "…" : "Undo (\(secondsRemaining))")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Color.evError)
                }
                .disabled(undoing)
            } else if undoneOrExpired {
                Text("Done").font(.system(size: 12, weight: .heavy)).foregroundStyle(.gray)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.evSurfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            // Start a connectable timer we can cancel on disappear so we
            // don't leak ticks for off-screen receipts.
            let publisher = Timer.publish(every: 1, on: .main, in: .common)
            timerCancellable = publisher.autoconnect().sink { _ in
                guard !undoneOrExpired else { return }
                secondsRemaining -= 1
                if secondsRemaining <= 0 { undoneOrExpired = true }
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
        undoneOrExpired = true
    }
}
