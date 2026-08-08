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
    var onPINAuthenticated: ((String) -> Void)? = nil

    private enum Phase { case enter, confirm }

    @State private var phase: Phase = .enter
    @State private var pin = ""
    @State private var firstEntry = ""
    @State private var error: String?
    @State private var shake = false
    @State private var pinStateRevision = 0
    @State private var checkingRemoteReset = true

    private var isFirstRun: Bool {
        _ = pinStateRevision
        return !store.isSet()
    }
    private let maxLen = 8
    private let minLen = 4
    private var canSubmit: Bool { pin.count >= minLen && !checkingRemoteReset }

    static func syncablePIN(
        enteredPIN: String,
        authenticated: Bool
    ) -> String? {
        authenticated ? enteredPIN : nil
    }

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
        .task {
            if await ParentPINSyncCoordinator.reconcileRemoteReset() {
                pin = ""
                firstEntry = ""
                phase = .enter
                pinStateRevision += 1
            }
            checkingRemoteReset = false
        }
    }

    private var dots: some View {
        // No fixed placeholder circles: render one filled dot per entered digit,
        // centered, so the row grows symmetrically out from the middle as the
        // parent types. New dots spring in; deletes spring out.
        HStack(spacing: 14) {
            ForEach(Array(0..<pin.count), id: \.self) { _ in
                Circle()
                    .fill(EvlinKidColors.green700)
                    .frame(width: 14, height: 14)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(minHeight: 14)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: pin.count)
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
            }
            .buttonStyle(KeypadKeyStyle(restingFill: .clear, restingText: EvlinKidColors.ink3))
        case "done":
            Button {
                if canSubmit { Task { await submit() } }
            } label: {
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
            }
            .buttonStyle(KeypadKeyStyle())
        }
    }

    private func tapDigit(_ d: String) {
        guard pin.count < maxLen else { return }
        pin.append(d)
        error = nil
    }

    private func submit() async {
        error = nil
        if !isFirstRun {
            checkingRemoteReset = true
            let cleared = await ParentPINSyncCoordinator.reconcileRemoteReset()
            checkingRemoteReset = false
            if cleared {
                pin = ""
                firstEntry = ""
                phase = .enter
                pinStateRevision += 1
                error = "This PIN was cleared. Create a new one."
                return
            }
            let authenticated = store.verify(pin)
            if let verifiedPIN = Self.syncablePIN(
                enteredPIN: pin,
                authenticated: authenticated
            ) {
                onPINAuthenticated?(verifiedPIN)
                onUnlocked()
            } else {
                fail("Wrong PIN.")
            }
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
            do {
                try store.setPIN(pin)
                ParentPINSyncCoordinator.captureNewPIN(pin)
                onPINAuthenticated?(pin)
                onUnlocked()
            }
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

/// Numeric-keypad key: flat at rest, and while pressed it fills with the same
/// dark green as the PIN dots (`green700`), flips its glyph white, scales down,
/// and gains a top-edge inner shadow — so a tap reads as "colour + sink in".
private struct KeypadKeyStyle: ButtonStyle {
    var restingFill: Color = .white
    var restingText: Color = EvlinKidColors.ink

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .foregroundStyle(pressed ? Color.white : restingText)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(pressed ? EvlinKidColors.green700 : restingFill)
            )
            .overlay(
                // Top-edge inner darkening that only shows while held, so the
                // key looks recessed rather than flat-tinted.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(pressed ? 0.22 : 0), .clear],
                            startPoint: .top, endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            )
            .scaleEffect(pressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.10), value: pressed)
    }
}
