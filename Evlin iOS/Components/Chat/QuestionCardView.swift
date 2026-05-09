//
//  QuestionCardView.swift
//  Evlin iOS
//
//  Strategy-agent Task 11.7 — renders a QuestionCard (single/multi/yes-no/
//  free-text) and reports the selected answer back via onAnswer. Cancel is
//  surfaced when the question is `cancellable`.
//

import SwiftUI

struct QuestionCardView: View {
    let card: QuestionCard
    let onAnswer: (AnswerQuestionBody) -> Void
    let onCancel: () -> Void

    @State private var multiSelected: Set<String> = []
    @State private var freeTextValue: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(card.prompt).font(.body)

            switch card.style {
            case .singleChoice, .yesNo:
                ForEach(effectiveOptions, id: \.value) { opt in
                    Button {
                        onAnswer(AnswerQuestionBody(
                            questionId: card.questionId,
                            selectedValues: [opt.value],
                            freeText: nil
                        ))
                    } label: {
                        Text(opt.label).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            case .multiChoice:
                ForEach(card.options, id: \.value) { opt in
                    Button {
                        if multiSelected.contains(opt.value) {
                            multiSelected.remove(opt.value)
                        } else {
                            multiSelected.insert(opt.value)
                        }
                    } label: {
                        HStack {
                            Image(systemName: multiSelected.contains(opt.value) ? "checkmark.square.fill" : "square")
                            Text(opt.label)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button("Submit") {
                    onAnswer(AnswerQuestionBody(
                        questionId: card.questionId,
                        selectedValues: Array(multiSelected),
                        freeText: nil
                    ))
                }
                .disabled(multiSelected.isEmpty)
                .buttonStyle(.borderedProminent)
            case .freeText:
                TextField("Type your answer", text: $freeTextValue, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button("Submit") {
                    onAnswer(AnswerQuestionBody(
                        questionId: card.questionId,
                        selectedValues: [],
                        freeText: freeTextValue
                    ))
                }
                .disabled(freeTextValue.isEmpty)
                .buttonStyle(.borderedProminent)
            }

            if card.cancellable {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.borderless)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// For yes_no, fall back to default Yes/No if backend sent zero options.
    private var effectiveOptions: [QuestionOption] {
        if card.style == .yesNo && card.options.isEmpty {
            return [
                QuestionOption(value: "yes", label: "Yes"),
                QuestionOption(value: "no",  label: "No"),
            ]
        }
        return card.options
    }
}
