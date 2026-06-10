import SwiftUI
import PhotosUI

/// Simple iOS-style profile editor — mirrors the design's `ChildEditSheet`
/// (HTML 936-1000): top bar (Cancel / title / Save), centred avatar with a
/// camera badge, then a Profile group of three rows (Full Name, Age, Status
/// note). Edits write back to the supplied bindings while the sheet is open.
///
/// Note: there is a separate `ChildEditSheet` (private) inside
/// `HomeSettingsSheet.swift` used for the parent-settings flow; this file
/// is the standalone profile editor reached from the kid profile screen.
struct ProfileEditSheet: View {
    @Binding var name: String
    @Binding var age: Int
    @Binding var subtitle: String
    @Binding var avatarURL: String?
    var isNew: Bool = false
    var onClose: () -> Void = {}
    var onSave: () -> Void = {}
    /// HP-2: when provided, the "Delete Child" row routes into the parent's
    /// REAL delete flow (ProfileView's confirm alert → DELETE
    /// /family/children/{id}). When nil the row is hidden — no visual stub.
    var onDelete: (() -> Void)? = nil

    @State private var draftName: String = ""
    @State private var draftAge: String = ""
    @State private var draftSubtitle: String = ""
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var pickedImageData: Data? = nil
    @State private var localPickedImage: UIImage? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 28) {
                    avatarBlock
                        .padding(.top, 28)
                    profileGroup
                    if !isNew, onDelete != nil { deleteGroup }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 60)
            }
        }
        .background(Color(hex: 0xF2F2F7))
        .onAppear {
            draftName = name
            draftAge = age == 0 ? "" : String(age)
            draftSubtitle = subtitle
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        pickedImageData = data
                        localPickedImage = UIImage(data: data)
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Text("Cancel")
                    .font(.custom("Inter", size: 17))
                    .foregroundStyle(Color(hex: 0x007AFF))
            }
            Spacer()
            Text(isNew ? "New Child" : "Edit Profile")
                .font(.custom("Inter", size: 17).weight(.semibold))
                .foregroundStyle(Color.black)
            Spacer()
            Button {
                commitDraft()
                onSave()
            } label: {
                Text("Save")
                    .font(.custom("Inter", size: 17).weight(.semibold))
                    .foregroundStyle(Color(hex: 0x007AFF))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            Color.white
                .overlay(Rectangle().fill(Color(hex: 0xE5E5EA)).frame(height: 1),
                         alignment: .bottom)
        )
    }

    // MARK: - Avatar block

    private var avatarBlock: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let img = localPickedImage {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else if let urlStr = avatarURL, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFill()
                            default:
                                ZStack {
                                    Color(hex: 0xE5E5EA)
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 36, weight: .medium))
                                        .foregroundStyle(Color(hex: 0x8E8E93))
                                }
                            }
                        }
                    } else {
                        ZStack {
                            Color(hex: 0xE5E5EA)
                            Image(systemName: "person.fill")
                                .font(.system(size: 36, weight: .medium))
                                .foregroundStyle(Color(hex: 0x8E8E93))
                        }
                    }
                }
                .frame(width: 88, height: 88)
                .clipShape(Circle())

                Circle()
                    .fill(Color(hex: 0x007AFF))
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(Color(hex: 0xF2F2F7), lineWidth: 2))
                    .overlay(
                        Image(systemName: "camera.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .offset(x: 2, y: 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Profile rows (iOS-style grouped table)

    private var profileGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROFILE")
                .font(.custom("Inter", size: 13).weight(.medium))
                .tracking(0.5)
                .foregroundStyle(Color(hex: 0x6C6C70))
                .padding(.leading, 4)

            VStack(spacing: 0) {
                fieldRow(placeholder: "Full Name", text: $draftName)
                divider
                fieldRow(placeholder: "Age", text: $draftAge, keyboard: .numberPad)
                divider
                fieldRow(placeholder: "Status note (e.g. Focused today)", text: $draftSubtitle)
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func fieldRow(placeholder: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(keyboard)
            .font(.custom("Inter", size: 16))
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
    }

    private var divider: some View {
        Rectangle().fill(Color(hex: 0xE5E5EA)).frame(height: 1)
            .padding(.leading, 16)
    }

    // MARK: - Delete group

    private var deleteGroup: some View {
        VStack(spacing: 0) {
            Button {
                // Routes into the parent's real delete confirm (HP-2) —
                // ProfileView closes this sheet and shows the destructive
                // alert that calls DELETE /family/children/{id}.
                onDelete?()
            } label: {
                HStack {
                    Text("Delete Child")
                        .font(.custom("Inter", size: 16))
                        .foregroundStyle(Color(hex: 0xFF3B30))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 44)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Commit

    private func commitDraft() {
        name = draftName.trimmingCharacters(in: .whitespaces)
        age = Int(draftAge.trimmingCharacters(in: .whitespaces)) ?? age
        subtitle = draftSubtitle.trimmingCharacters(in: .whitespaces)
        // For the photo pick we don't have an upload pipeline yet; we keep
        // the in-memory bitmap visible via `localPickedImage` while the
        // sheet is alive (parent rebinds avatarURL only if you wire it up
        // to a remote uploader).
        _ = pickedImageData
    }
}

#Preview {
    ProfileEditSheet(
        name: .constant("Liam"),
        age: .constant(12),
        subtitle: .constant("Focused today"),
        avatarURL: .constant(nil)
    )
}
