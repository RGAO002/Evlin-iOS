import SwiftUI

/// Draggable float: `@AppStorage("appMode")` **parent ↔ child**.
/// Universal **Parent ⇄ Child** quick switch (all builds once onboarding + mode shell is shown).
///
/// Position persists via `evlin.debugToggle.{x,y}`. Defaults above the home indicator bottom-right.
struct FloatingModeToggle: View {
    @AppStorage("appMode") private var appMode: String = "parent"
    @AppStorage("evlin.debugToggle.x") private var savedX: Double = -1
    @AppStorage("evlin.debugToggle.y") private var savedY: Double = -1

    @State private var dragOffset: CGSize = .zero
    @State private var position: CGPoint = .zero

    private let buttonSize: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            label
                .frame(width: buttonSize, height: buttonSize)
                .position(currentPosition(in: geo.size))
                .gesture(dragGesture(in: geo.size))
                .onAppear { initializePositionIfNeeded(in: geo.size) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(true)
    }

    private var label: some View {
        Button {
            let nextMode = (appMode == "parent") ? "child" : "parent"
            if nextMode == "child" {
                EvlinDemoShortcuts.seedPlaceholderChildUUIDIfMissing()
            }
            appMode = nextMode
        } label: {
            ZStack {
                Circle()
                    .fill(.thinMaterial)
                    .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                Text(appMode == "parent" ? "P" : "K")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(appMode == "parent"
                                     ? Color(red: 0x04/255, green: 0x16/255, blue: 0x27/255)
                                     : Color(red: 0x2A/255, green: 0xA8/255, blue: 0x54/255))
            }
        }
        .buttonStyle(.plain)
    }

    private func currentPosition(in size: CGSize) -> CGPoint {
        CGPoint(x: position.x + dragOffset.width,
                y: position.y + dragOffset.height)
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in dragOffset = value.translation }
            .onEnded { value in
                let newX = clamp(position.x + value.translation.width,
                                 buttonSize / 2, size.width - buttonSize / 2)
                let newY = clamp(position.y + value.translation.height,
                                 buttonSize / 2 + 24, size.height - buttonSize / 2 - 24)
                position = CGPoint(x: newX, y: newY)
                savedX = Double(newX)
                savedY = Double(newY)
                dragOffset = .zero
            }
    }

    private func initializePositionIfNeeded(in size: CGSize) {
        guard position == .zero else { return }
        if savedX < 0 || savedY < 0 {
            position = CGPoint(x: size.width - buttonSize / 2 - 16,
                               y: size.height - buttonSize / 2 - 50)
        } else {
            position = CGPoint(x: clamp(savedX, buttonSize / 2, size.width - buttonSize / 2),
                               y: clamp(savedY, buttonSize / 2, size.height - buttonSize / 2))
        }
    }

    private func clamp<T: Comparable>(_ x: T, _ lo: T, _ hi: T) -> T {
        min(max(x, lo), hi)
    }
}

#if DEBUG
#Preview {
    ZStack {
        Color.gray.opacity(0.2).ignoresSafeArea()
        FloatingModeToggle()
    }
}
#endif
