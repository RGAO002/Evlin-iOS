import SwiftUI

struct AddChildStep: View {
    @Binding var name: String
    let onContinue: () -> Void
    @State private var age: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Add your child")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("Personalize Evlin so it can reference your child by name.")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            .padding(.top, Spacing.section)

            VStack(spacing: Spacing.xl) {
                field(label: "NAME", placeholder: "Liam", text: $name, keyboard: .default)
                field(label: "AGE (OPTIONAL)", placeholder: "8", text: $age, keyboard: .numberPad)
            }

            Spacer()

            Button(action: onContinue) {
                Text("Continue")
                    .font(.evLabelLarge)
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(Color.evOnPrimary)
            .padding(.vertical, Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(name.trimmingCharacters(in: .whitespaces).isEmpty ? Color.evOutline : Color.evPrimary)
            )
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.evSurface)
    }

    @ViewBuilder
    private func field(label: String, placeholder: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(label)
                .font(.evLabelMedium)
                .foregroundStyle(Color.evOutline)
                .evLabelStyle()
            TextField(placeholder, text: text)
                .font(.evBodyMedium)
                .keyboardType(keyboard)
                .padding(Spacing.lg)
                .background(Color.evSurfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
        }
    }
}
