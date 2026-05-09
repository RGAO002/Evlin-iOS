//
//  AssistantFeedbackButtons.swift
//  Evlin iOS
//
//  Strategy-agent Task 11.8 — 👍/👎 row rendered beneath each assistant
//  bubble. Disables itself after a single submission to avoid duplicate
//  feedback rows.
//

import SwiftUI

struct AssistantFeedbackButtons: View {
    let messageId: String
    let onTap: (ChatFeedbackRating) -> Void

    @State private var submitted: ChatFeedbackRating?

    var body: some View {
        HStack(spacing: 16) {
            Button {
                submitted = .thumbsUp
                onTap(.thumbsUp)
            } label: {
                Image(systemName: submitted == .thumbsUp ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            .disabled(submitted != nil)

            Button {
                submitted = .thumbsDown
                onTap(.thumbsDown)
            } label: {
                Image(systemName: submitted == .thumbsDown ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
            .disabled(submitted != nil)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .font(.footnote)
    }
}
