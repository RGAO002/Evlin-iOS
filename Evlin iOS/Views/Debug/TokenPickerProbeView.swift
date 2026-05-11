// Evlin iOS/Evlin iOS/Views/Debug/TokenPickerProbeView.swift
//
// Manual driver for `TokenPickerView`. Simulates the lazy-tag flow chat will
// trigger when an alias resolution misses: parent enters a hint, taps "Open
// picker", picks the right token, the alias gets persisted, and we verify
// the round-trip lookup works.
import SwiftUI
import FamilyControls
import ManagedSettings

struct TokenPickerProbeView: View {
    @State private var hint: String = "Instagram"
    @State private var pickerKind: TokenPickerView.Kind = .app
    @State private var pickerOpen = false
    @State private var lastResult: String = ""

    var body: some View {
        Form {
            Section {
                Text("Pretend the AI just said: \"Shield <hint>\". If LocalAliasStore doesn't know <hint>, this picker would normally pop up inside chat. Use this to verify the picker + alias-save round-trip works.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hint to resolve") {
                TextField("Instagram", text: $hint)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()

                Picker("Token kind", selection: $pickerKind) {
                    Text("Application").tag(TokenPickerView.Kind.app)
                    Text("Category").tag(TokenPickerView.Kind.category)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Button {
                    pickerOpen = true
                } label: {
                    Label("Open picker", systemImage: "tag.fill")
                }
                .disabled(hint.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    lookupNow()
                } label: {
                    Label("Lookup hint in LocalAliasStore", systemImage: "magnifyingglass")
                }
            }

            if !lastResult.isEmpty {
                Section("Result") {
                    Text(lastResult)
                        .font(.caption.monospaced())
                        .foregroundStyle(lastResult.hasPrefix("✓") ? Color.green : Color.orange)
                }
            }
        }
        .navigationTitle("Lazy-tag picker test")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $pickerOpen) {
            TokenPickerView(hint: hint, kind: pickerKind) { picked in
                if picked != nil {
                    lastResult = "✓ Saved alias \"\(hint)\" → token. Now verifying lookup…"
                    // Verify round-trip immediately so we know the persistence
                    // actually wrote and is readable from this same store.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        verifyLookup()
                    }
                } else {
                    lastResult = "⊘ Skipped — no alias saved."
                }
            }
        }
    }

    private func lookupNow() {
        verifyLookup()
    }

    private func verifyLookup() {
        let store = LocalAliasStore.shared
        switch pickerKind {
        case .app:
            if store.applicationToken(forLookupKey: hint) != nil {
                lastResult = "✓ App alias hit: \"\(hint)\" resolves to a token."
            } else {
                lastResult = "✗ App alias miss: no token saved for \"\(hint)\" yet. Tap Open picker."
            }
        case .category:
            if store.categoryToken(forName: hint) != nil {
                lastResult = "✓ Category alias hit: \"\(hint)\" resolves to a token."
            } else {
                lastResult = "✗ Category alias miss: no token saved for \"\(hint)\" yet. Tap Open picker."
            }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { TokenPickerProbeView() }
}
#endif
