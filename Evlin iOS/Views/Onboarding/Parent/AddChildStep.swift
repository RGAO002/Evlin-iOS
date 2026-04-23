import SwiftUI

struct AddChildStep: View {
    @Binding var name: String
    let onContinue: () -> Void
    @State private var age: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add your child")
                .font(.evHeadlineLarge)
                .padding(.top, 40)
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Liam", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Age (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("8", text: $age)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
            }
            Spacer()
            Button(action: onContinue) {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
    }
}
