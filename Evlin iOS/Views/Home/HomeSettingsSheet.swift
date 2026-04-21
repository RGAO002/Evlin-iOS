import SwiftUI

struct HomeSettingsSheet: View {
    var onClose: () -> Void
    @State private var children: [ChildProfile] = ChildProfile.all
    @State private var editing: ChildProfile? = nil
    @State private var adding: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Family") {
                    ForEach(children) { c in
                        Button {
                            editing = c
                        } label: {
                            HStack(spacing: 12) {
                                EvlinAvatarView(url: c.avatarURL, name: c.name, size: 36)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name)
                                        .font(.custom("Manrope", size: 14).weight(.bold))
                                        .foregroundStyle(Color.evOnSurface)
                                    Text("Age \(c.age)")
                                        .font(.custom("Inter", size: 12))
                                        .foregroundStyle(Color.evOnSurfaceVariant)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.evOutline)
                            }
                        }
                    }
                    .onDelete { children.remove(atOffsets: $0) }

                    Button {
                        adding = true
                    } label: {
                        Label("Add child", systemImage: "plus.circle.fill")
                            .foregroundStyle(Color.evPrimary)
                    }
                }

                Section("App") {
                    LabeledContent("Parent name") {
                        ParentNameField()
                    }
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }
                }
            }
            .sheet(item: $editing) { child in
                ChildEditSheet(child: child) { updated in
                    if let idx = children.firstIndex(where: { $0.id == updated.id }) {
                        children[idx] = updated
                    }
                    editing = nil
                }
            }
            .sheet(isPresented: $adding) {
                ChildEditSheet(child: nil) { newChild in
                    children.append(newChild)
                    adding = false
                }
            }
        }
    }
}

private struct ParentNameField: View {
    @AppStorage("parentName") private var parentName: String = "Morgan"
    var body: some View {
        TextField("", text: $parentName)
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.plain)
    }
}

private struct ChildEditSheet: View {
    let child: ChildProfile?
    var onSave: (ChildProfile) -> Void

    @State private var name: String = ""
    @State private var age: Int = 8

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                    Stepper("Age: \(age)", value: $age, in: 1...18)
                }
            }
            .navigationTitle(child == nil ? "Add child" : "Edit \(child?.name ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let c = child {
                    name = c.name
                    age = c.age
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let id = child?.id ?? name.lowercased()
                        let updated = ChildProfile(
                            id: id, name: name, age: age,
                            avatarURL: child?.avatarURL,
                            accentColor: child?.accentColor ?? .evPrimary,
                            status: child?.status ?? .unlocked,
                            timeLeft: child?.timeLeft ?? "1h",
                            timePct: child?.timePct ?? 0.5,
                            subtitle: child?.subtitle ?? "New family member"
                        )
                        onSave(updated)
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}
