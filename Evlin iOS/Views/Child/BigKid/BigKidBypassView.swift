import SwiftUI

struct BigKidBypassView: View {
    let task: BigKidTask
    var onBack: () -> Void
    var onSend: (String) async -> Void

    @State private var text: String = ""
    @State private var sent: Bool = false
    @State private var sending: Bool = false

    var body: some View {
        Group { sent ? AnyView(sentView) : AnyView(formView) }
            .background(EvlinKidColors.surface.ignoresSafeArea())
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 0) {
            EvKidBackButton(label: "Back", action: onBack)
                .padding(.top, 8)
            (
                Text("For: ")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(EvlinKidColors.ink3)
                +
                Text(task.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(EvlinKidColors.ink2)
            )
            .padding(.top, 6)
            Text("Tell your parent why")
                .font(.system(size: 28, weight: .heavy))
                .tracking(-0.7)
                .foregroundStyle(EvlinKidColors.ink)
                .padding(.top, 18)
                .padding(.bottom, 8)
            Text("What's stopping you from doing this today? Write it out and your parent will decide if it's okay to skip.")
                .font(.system(size: 15))
                .foregroundStyle(EvlinKidColors.ink2)
                .lineSpacing(3)
                .padding(.bottom, 20)
            TextField("e.g. I had football practice and got home too late.",
                      text: $text, axis: .vertical)
                .lineLimit(8...20)
                .font(.system(size: 16))
                .padding(18)
                .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                .background(EvlinKidColors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(EvlinKidColors.line, lineWidth: 1.5)
                )
            Spacer(minLength: 18)
            EvKidBigButton(isDisabled: text.trimmingCharacters(in: .whitespaces).isEmpty || sending,
                           action: send) {
                Text(sending ? "Sending…" : "Send to parent")
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
    }

    private func send() {
        sending = true
        Task {
            await onSend(text)
            sent = true
            sending = false
        }
    }

    private var sentView: some View {
        VStack(spacing: 0) {
            HStack { EvKidBackButton(label: "Home", action: onBack); Spacer() }
                .padding(.top, 8)
                .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
            Spacer()
            VStack(spacing: 24) {
                ZStack {
                    Circle().fill(EvlinKidColors.green100)
                        .frame(width: 88, height: 88)
                    Circle().fill(EvlinKidColors.green500)
                        .frame(width: 60, height: 60)
                        .shadow(color: EvlinKidColors.green500.opacity(0.25), radius: 12, y: 6)
                    Image(systemName: "checkmark")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("Your parent has been notified")
                    .font(.system(size: 26, weight: .heavy))
                    .tracking(-0.6)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(EvlinKidColors.ink)
                Text("Wait for their response. They'll let you know if you can skip this task today.")
                    .font(.system(size: 15))
                    .foregroundStyle(EvlinKidColors.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .lineSpacing(3)
            }
            Spacer()
            EvKidBigButton(tone: .ghost, action: onBack) { Text("Back to home") }
                .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
                .padding(.bottom, 32)
        }
    }
}

#if DEBUG
#Preview("Form") {
    BigKidBypassView(task: .fixture(), onBack: {}, onSend: { _ in })
}
#endif
