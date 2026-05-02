import SwiftUI

/// Cancel / Title / Save header + natural-height body. See HTML 1196-1217.
/// Use as the root of every Add*/Edit* form sheet.
///
/// Sizing: the body is a plain `VStack` (no ScrollView). FormShell's
/// natural height is exactly `header + divider + sum(fields)`, which
/// lets the surrounding `EvlinSheetCard` collapse around its content.
/// All current forms fit comfortably in ~half-screen, so we don't pay
/// for ScrollView's "fill all offered space" behaviour. If a future
/// form ever needs scrolling, wrap its FormShell content in a
/// `ScrollView` at the call site.
struct FormShell<Content: View>: View {
    let title: String
    var canSave: Bool = true
    var saveLabel: String = "Save"
    let onCancel: () -> Void
    let onSave: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", action: onCancel)
                    .font(.custom("Inter", size: 14))
                    .foregroundStyle(Color.evOnSurfaceVariant)

                Spacer()

                Text(title)
                    .font(.custom("Manrope", size: 17).weight(.heavy))
                    .foregroundStyle(Color.evPrimary)

                Spacer()

                Button(saveLabel, action: onSave)
                    .font(.custom("Inter", size: 14).weight(.heavy))
                    .foregroundStyle(canSave ? Color.evPrimary : Color.evOutline)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            VStack(spacing: 16) {
                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

/// Field wrapper with uppercase label above input. See HTML 1210-1217.
struct FormField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(Color.evOnSurfaceVariant)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// TextField input style matching HTML 1194 (FORM_INPUT). We use
/// `strokeBorder` rather than `stroke` so the 1.5pt line is fully inside
/// the rounded rectangle bounds (CSS `box-sizing: border-box` parity);
/// `stroke` puts half outside the path which makes inputs render ~1pt
/// taller than the design and creates a faint "shadow halo" along the
/// edge.
extension View {
    func evlinFormInput() -> some View {
        self
            .font(.custom("Inter", size: 14))
            .foregroundStyle(Color.evOnSurface)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.evSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.evOutlineVariant, lineWidth: 1)
            )
    }
}

/// Pill button used in form category/repeat selectors. See HTML 1230 / 1285.
struct FormPillSelector<Item: Hashable>: View {
    let items: [(value: Item, label: String)]
    @Binding var selected: Item

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.value) { item in
                Button {
                    selected = item.value
                } label: {
                    Text(item.label)
                        .font(.custom("Inter", size: 11).weight(.heavy))
                        .foregroundStyle(selected == item.value ? Color.evPrimary : Color.evOnSurfaceVariant)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(selected == item.value ? Color.evPrimary.opacity(0.06) : Color.white)
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(selected == item.value ? Color.evPrimary : Color.evOutlineVariant,
                                              lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Simple flow layout for pills (wraps when row is full).
///
/// IMPORTANT: when measured with an unconstrained proposal (e.g. the
/// hidden measurement layer in `EvlinSheetCard`, where `fixedSize`
/// strips the height proposal), `proposal.width` is nil. We default to
/// `.infinity` rather than 0 so items lay out in a single row instead
/// of wrapping after every item — otherwise a 7-icon picker would
/// report 7 rows of natural height and inflate the surrounding sheet
/// to ~full screen.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(in: proposal.width ?? .infinity, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(in: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var maxX: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            rowH = max(rowH, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (frames, CGSize(width: maxX, height: y + rowH))
    }
}
