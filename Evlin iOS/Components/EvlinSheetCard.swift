import SwiftUI

/// Custom bottom-sheet style overlay used in place of the system
/// `.sheet`. Forces a white card on a translucent dim backdrop so we
/// never inherit the system sheet's dark background in dark mode.
///
/// Use as a top-level overlay alongside the rest of the screen, gated
/// by an `isPresented` binding (the pattern matches `EventDetailCard`):
///
/// ```swift
/// ZStack {
///     mainContent
///     EvlinSheetCard(isPresented: $showSheet) {
///         AddBottomSheet(...)
///     }
/// }
/// ```
///
/// Behaviour:
/// - Dim backdrop tap dismisses.
/// - Card slides up from the bottom on present, slides down on dismiss
///   — the outer ZStack stays mounted so the inserted-then-removed
///   transitions on the conditional backdrop and card actually animate.
/// - A drag-handle bar near the top (default visible) lets the user
///   swipe-down to dismiss as well, mirroring iOS sheet conventions.
/// - Card hugs its content's natural height (capped at
///   `maxHeightFraction × screen` so giant forms don't run off-screen).
///   No drop shadow — feedback was that even a soft halo read as
///   "shadow noise" on the in-content cards.
struct EvlinSheetCard<Content: View>: View {
    @Binding var isPresented: Bool
    var maxHeightFraction: CGFloat = 0.86
    var showsHandle: Bool = true
    @ViewBuilder let content: Content

    @State private var dragOffset: CGFloat = 0
    @State private var measuredHeight: CGFloat = 0
    @GestureState private var isDragging: Bool = false

    var body: some View {
        // Outer ZStack is ALWAYS mounted, even when nothing is shown.
        // That's what lets the `.animation(value: isPresented)` modifier
        // observe the boolean flip and animate the conditional inserts
        // below; if we wrapped the whole thing in `if isPresented {…}`
        // the modifier would only exist while presented, so the
        // appear-from-bottom transition would render as a hard cut.
        ZStack(alignment: .bottom) {
            if isPresented {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { dismiss() }
            }

            if isPresented {
                cardStack
                    .transition(.move(edge: .bottom))
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .preferredColorScheme(.light)
        .animation(.spring(response: 0.36, dampingFraction: 0.86),
                   value: isPresented)
        .animation(.interactiveSpring(response: 0.28,
                                      dampingFraction: 0.8),
                   value: dragOffset)
        .onChange(of: isPresented) { _, newValue in
            // Reset drag state on every fresh presentation so a
            // partial drag-then-dismiss doesn't leak into the next
            // show. We do it on the rising edge specifically so the
            // exit transition keeps the user's drag-down offset and
            // looks continuous.
            if newValue { dragOffset = 0 }
        }
    }

    /// The actual white card. We measure the inner natural content
    /// height through a hidden copy and then apply that exact height
    /// to a separately-rendered visible copy. This is the only
    /// reliable way in SwiftUI to make a card hug its content when
    /// the content tree contains layout-flexible views (Spacers,
    /// `axis: .vertical` TextFields, `ScrollView`, etc.) that would
    /// otherwise grow to fill any space the parent offers them.
    ///
    /// The measurement layer is `.frame(width: screenWidth)` so that
    /// children using container layouts (`FlowLayout`, `LazyVGrid`,
    /// etc.) compute the same wrapping behaviour as the visible card.
    /// Without this, an unconstrained-width proposal would report
    /// every flow-laid-out pill on its own row, making the natural
    /// height balloon to the entire screen.
    private var cardStack: some View {
        ZStack(alignment: .top) {
            cardContent
                .frame(width: UIScreen.main.bounds.width)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: SheetContentHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
                .hidden()

            cardContent
                .frame(height: clampedHeight)
                .clipped()
        }
        .onPreferenceChange(SheetContentHeightKey.self) { newValue in
            // Only react to meaningful deltas to dodge feedback loops.
            if abs(newValue - measuredHeight) > 0.5 {
                measuredHeight = newValue
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                topTrailingRadius: 24,
                style: .continuous
            )
            .fill(Color.white)
        )
        .offset(y: dragOffset)
        .gesture(dragGesture)
    }

    private var cardContent: some View {
        VStack(spacing: 0) {
            if showsHandle {
                Capsule()
                    .fill(Color.evOutlineVariant)
                    .frame(width: 40, height: 4)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }
            content
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var clampedHeight: CGFloat {
        // Until the first measurement lands, pretend the card is
        // empty so it doesn't flash at full height for a frame.
        guard measuredHeight > 0 else { return 0 }
        return min(measuredHeight, maxCardHeight)
    }

    private var maxCardHeight: CGFloat {
        UIScreen.main.bounds.height * maxHeightFraction
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                // Only follow downward drags. Upward drags are absorbed
                // (dragOffset stays at 0) so the card's bottom edge
                // remains flush against the bottom of the screen / tab
                // bar. Otherwise dragging up would expose a visible
                // gap below the card, which feedback explicitly called
                // out as wrong.
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height > 90 || value.predictedEndTranslation.height > 200 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func dismiss() {
        // Just flip the binding — the outer ZStack's animation and the
        // card's `.transition(.move(edge: .bottom))` handle the slide-
        // down. Keeping the user's current `dragOffset` in place makes
        // the exit feel like a continuation of their drag instead of a
        // snap-back-then-slide.
        isPresented = false
    }
}

/// Reports the natural height of the hidden measurement copy of the
/// sheet's content tree. The visible copy then frames to that exact
/// value (capped) so the card can never be taller than its content.
private struct SheetContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Variant that takes an `Identifiable` binding (parallels `.sheet(item:)`).
/// The wrapper renders `EvlinSheetCard` unconditionally and only the
/// content closure is gated on `item`, which is what keeps the
/// presentation transitions intact.
struct EvlinSheetCardItem<Item: Identifiable, Content: View>: View {
    @Binding var item: Item?
    var maxHeightFraction: CGFloat = 0.86
    var showsHandle: Bool = true
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        EvlinSheetCard(
            isPresented: Binding(
                get: { item != nil },
                set: { if !$0 { item = nil } }
            ),
            maxHeightFraction: maxHeightFraction,
            showsHandle: showsHandle
        ) {
            if let active = item {
                content(active)
            }
        }
    }
}
