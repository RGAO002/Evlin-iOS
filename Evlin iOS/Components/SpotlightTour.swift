//
//  SpotlightTour.swift
//  Evlin iOS
//
//  Reusable first-run spotlight tour: dims the screen, cuts a rounded hole
//  over one target at a time, and explains it in a bubble. Tap anywhere to
//  advance; Skip (always visible) ends the WHOLE tour immediately.
//
//  Usage:
//    1. Mark targets anywhere in the tree:  .tourTarget("home.bell")
//    2. At the level where all targets' preferences have merged:
//         .overlayPreferenceValue(TourAnchorKey.self) { anchors in
//             if showTour { SpotlightTourOverlay(steps:…, anchors:…, onEnd:…) }
//         }
//
//  Robustness rules (mirrors the approved HTML mockup):
//  - A step whose target is missing/zero-sized is skipped; if none remain the
//    tour ends itself instead of drawing a wrong hole.
//  - The presenter decides WHEN to show (queueing behind e.g. the agreement
//    gate) and marks its "seen" flag at display time, so an interruption
//    never re-nags.
//

import SwiftUI

extension Notification.Name {
    /// Posted by presenters whose tour targets live in OTHER views' scroll
    /// views (e.g. ParentRootView's per-tab tours → Library/Insights lists).
    /// userInfo: ["target": String]. The owning view scrolls its own reader.
    static let evlinTourStepChanged = Notification.Name("evlinTourStepChanged")
}

// MARK: - Target marking

struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Mark this view as a spotlight-tour target. `enabled: false` lets a
    /// row inside a ForEach tag only its first instance.
    func tourTarget(_ id: String, enabled: Bool = true) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) {
            enabled ? [id: $0] : [:]
        }
    }
}

// MARK: - Steps

struct TourStep {
    let target: String
    let text: String
    var padding: CGFloat = 6
    var cornerRadius: CGFloat = 18
}

// MARK: - Cutout shape (animatable hole)

private struct TourCutoutShape: Shape {
    var hole: CGRect
    var corner: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(hole.minX, hole.minY),
                             AnimatablePair(hole.width, hole.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second,
                            width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(rect)
        p.addRoundedRect(in: hole,
                         cornerSize: CGSize(width: corner, height: corner),
                         style: .continuous)
        return p
    }
}

// MARK: - Overlay

struct SpotlightTourOverlay: View {
    let steps: [TourStep]
    let anchors: [String: Anchor<CGRect>]
    /// Label of the final step's button ("Start exploring" / "Done").
    var lastButtonTitle: String = "Start exploring"
    /// Called with the new step's target id whenever the tour moves (including
    /// the first step). Presenters whose targets live in a ScrollView use this
    /// with a ScrollViewReader to scroll the target into view — the hole
    /// tracks the anchors live while the content scrolls.
    var onStepChange: ((String) -> Void)? = nil
    /// Called exactly once when the tour ends (finished, skipped, or no
    /// resolvable targets).
    let onEnd: () -> Void

    @State private var index = 0
    @State private var ended = false

    private let tipWidth: CGFloat = 250

    var body: some View {
        GeometryReader { proxy in
            // Only steps whose target is actually on screen (mockup rule:
            // never draw a hole over nothing).
            let visible = steps.filter { step in
                guard let a = anchors[step.target] else { return false }
                let r = proxy[a]
                return r.width > 0 && r.height > 0
            }

            if visible.isEmpty {
                Color.clear.onAppear { end() }
            } else {
                let step = visible[min(index, visible.count - 1)]
                let hole = proxy[anchors[step.target]!]
                    .insetBy(dx: -step.padding, dy: -step.padding)
                let isLast = index >= visible.count - 1

                ZStack {
                    // Dim + cutout. eoFill keeps the hole transparent.
                    // NOTE: no .ignoresSafeArea() here — the whole overlay
                    // (see below) already spans the full screen, so the shape
                    // and the anchor rects share one coordinate space. Mixing
                    // spaces shifts every hole up by the top safe-area inset.
                    TourCutoutShape(hole: hole, corner: step.cornerRadius)
                        .fill(Color.black.opacity(0.58), style: FillStyle(eoFill: true))

                    // White ring around the hole.
                    RoundedRectangle(cornerRadius: step.cornerRadius + 3, style: .continuous)
                        .stroke(Color.white.opacity(0.85), lineWidth: 2)
                        .frame(width: hole.width + 6, height: hole.height + 6)
                        .position(x: hole.midX, y: hole.midY)

                    tooltip(for: step, hole: hole, isLast: isLast, in: proxy.size,
                            safeArea: proxy.safeAreaInsets,
                            totalSteps: visible.count,
                            onBack: index > 0 ? { index -= 1 } : nil,
                            onNext: { advance(total: visible.count) })
                }
                .contentShape(Rectangle())
                .onTapGesture { advance(total: visible.count) }
                .overlay(alignment: .topTrailing) {
                    Button("Skip") { end() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                        // The overlay ignores the safe area, so pad Skip back
                        // below the status bar by the inset the proxy reports.
                        .padding(.top, proxy.safeAreaInsets.top + 8)
                        .padding(.trailing, 18)
                }
                .animation(.spring(response: 0.38, dampingFraction: 0.86), value: index)
                .onAppear { onStepChange?(visible[0].target) }
                .onChange(of: index) { _, i in
                    onStepChange?(visible[min(i, visible.count - 1)].target)
                }
            }
        }
        // One full-screen coordinate space for anchors, cutout, and tooltip:
        // the GeometryReader itself extends under the bars, so proxy[anchor]
        // resolves in the same space the shape draws in.
        .ignoresSafeArea()
        .transition(.opacity)
        .accessibilityAddTraits(.isModal)
    }

    private func advance(total: Int) {
        if index + 1 < total { index += 1 } else { end() }
    }

    private func end() {
        guard !ended else { return }
        ended = true
        onEnd()
    }

    @ViewBuilder
    private func tooltip(for step: TourStep, hole: CGRect,
                         isLast: Bool, in size: CGSize,
                         safeArea: EdgeInsets,
                         totalSteps: Int,
                         onBack: (() -> Void)?,
                         onNext: @escaping () -> Void) -> some View {
        let gap: CGFloat = 14
        let tipHeight: CGFloat = 120   // estimate for placement math only
        let below = hole.maxY + gap + tipHeight < size.height - safeArea.bottom
        let rawY = below ? hole.maxY + gap + tipHeight / 2
                         : hole.minY - gap - tipHeight / 2
        let y = min(max(safeArea.top + tipHeight / 2, rawY),
                    size.height - safeArea.bottom - tipHeight / 2)
        let x = min(max(tipWidth / 2 + 12, hole.midX), size.width - tipWidth / 2 - 12)

        VStack(alignment: .leading, spacing: 6) {
            Text("\(index + 1) / \(totalSteps)")
                .font(.system(size: 10, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(Color.evPrimary.opacity(0.65))
            Text(step.text)
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundStyle(Color.evOnSurface)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                HStack(spacing: 5) {
                    ForEach(0..<totalSteps, id: \.self) { i in
                        Circle()
                            .fill(i == index ? Color.evPrimary : Color.evOutlineVariant)
                            .frame(width: 6, height: 6)
                    }
                }
                Spacer()
                // Back to the previous stop (hidden on the first one).
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.evOnSurfaceVariant)
                            .padding(.horizontal, 9).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.evOutlineVariant, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous step")
                }
                // Tapping anywhere also advances; the button is the explicit
                // affordance and the VoiceOver path.
                Button(action: onNext) {
                    Text(isLast ? lastButtonTitle : "Next")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.evPrimary))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: tipWidth)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white)
            .shadow(color: .black.opacity(0.28), radius: 16, y: 6))
        .position(x: x, y: y)
    }
}
