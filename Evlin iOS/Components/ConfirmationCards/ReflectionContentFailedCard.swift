//
//  ReflectionContentFailedCard.swift
//  Evlin iOS
//
//  Phase 2B: Shown when reflection.content_generation_failed is emitted.
//  Offers three recovery paths:
//    Retry             → handlers.onPrimary  → patch {"intent_confirmed": true}
//    Use simpler template → handlers.onSecondary → patch {"use_simpler_template": true}
//    Cancel            → handlers.onCancel
//

import SwiftUI

struct ReflectionContentFailedCard: View {
    let payload: CardPayload
    let onRetry: () -> Void
    let onSimplerTemplate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(payload.title)
                .font(.headline)
            if !payload.body.isEmpty {
                Text(payload.body)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                Button("Retry", action: onRetry)
                    .buttonStyle(.bordered)
                Button("Use simpler template", action: onSimplerTemplate)
                    .buttonStyle(.bordered)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
