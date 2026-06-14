import SwiftUI

/// Evlin PIN gate — numeric keypad. First run sets + confirms a PIN; later
/// entries unlock. Parent-only edits on the child device. There is intentionally
/// NO "Forgot PIN" affordance: a confirmation alert is not authentication, so any
/// in-gate "clear + re-set" path would let the gated child bypass straight into
/// Parent controls. A parent who forgets recovers out of band (reinstall, or a
/// future parent-app remote reset).
struct EvlinPINGateView: View {
    let store: EvlinPINStore
    let onUnlocked: () -> Void
    let onCancel: () -> Void

    private enum Phase { case enter, confirm }

    @State private var phase: Phase = .enter
    @State private var pin = ""
    @State private var firstEntry = ""
    @State private var error: String?
    @State private var shake = false

    private var isFirstRun: Bool { !store.isSet() }
    private let maxLen = 8
    private let minLen = 4
    private var canSubmit: Bool { pin.count >= minLen }

    private var title: String {
        if !isFirstRun { return "Enter parent PIN" }
        return phase == .enter ? "Create a PIN" : "Confirm PIN"
    }
    private var subtitle: String {
        isFirstRun ? "Your child can't change managed apps without it." : "to manage settings on this phone"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { onCancel() }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(EvlinKidColors.ink3)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Spacer(minLength: 12)

            ZStack {
                Circle().fill(EvlinKidColors.green100).frame(width: 56, height: 56)
                Image(systemName: "lock.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(EvlinKidColors.green700)
            }
            Text(title)
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(EvlinKidColors.ink)
                .padding(.top, 14)
            Text(subtitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(EvlinKidColors.ink3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 4)

            dots
                .padding(.top, 22)
                .offset(x: shake ? -8 : 0)
                .animation(.default, value: shake)

            Text(error ?? " ")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.red)
                .padding(.top, 10)

            Spacer(minLength: 8)

            keypad
                .padding(.horizontal, 28)
                .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EvlinKidColors.surface2.ignoresSafeArea())
    }

    private var dots: some View {
        HStack(spacing: 14) {
            ForEach(0..<maxLen, id: \.self) { i in
                Circle()
                    .fill(i < pin.count ? EvlinKidColors.green700 : Color.clear)
                    .overlay(Circle().stroke(EvlinKidColors.ink3.opacity(0.4), lineWidth: i < pin.count ? 0 : 1.5))
                    .frame(width: 13, height: 13)
            }
        }
    }

    private var keypad: some View {
        let keys: [String] = ["1","2","3","4","5","6","7","8","9","done","0","del"]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            ForEach(keys, id: \.self) { key in
                keyButton(key)
            }
        }
    }

    @ViewBuilder
    private func keyButton(_ key: String) -> some View {
        switch key {
        case "del":
            Button { if !pin.isEmpty { pin.removeLast(); error = nil } } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(EvlinKidColors.ink3)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.plain)
        case "done":
            Button { if canSubmit { submit() } } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(canSubmit ? .white : EvlinKidColors.ink3)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(RoundedRectangle(cornerRadius: 12).fill(canSubmit ? EvlinKidColors.green700 : EvlinKidColors.green100))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        default:
            Button { tapDigit(key) } label: {
                Text(key)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(EvlinKidColors.ink)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
            }
            .buttonStyle(.plain)
        }
    }

    private func tapDigit(_ d: String) {
        guard pin.count < maxLen else { return }
        pin.append(d)
        error = nil
    }

    private func submit() {
        error = nil
        if !isFirstRun {
            if store.verify(pin) { onUnlocked() } else { fail("Wrong PIN.") }
            return
        }
        switch phase {
        case .enter:
            firstEntry = pin
            pin = ""
            phase = .confirm
        case .confirm:
            guard pin == firstEntry else {
                phase = .enter; firstEntry = ""; fail("PINs don't match."); return
            }
            do { try store.setPIN(pin); onUnlocked() }
            catch EvlinPINStore.PINError.invalidLength {
                phase = .enter; firstEntry = ""; fail("PIN must be 4–8 digits.")
            } catch { phase = .enter; firstEntry = ""; fail("Couldn't save PIN. Try again.") }
        }
    }

    private func fail(_ message: String) {
        error = message
        pin = ""
        shake = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { shake = false }
    }
}
