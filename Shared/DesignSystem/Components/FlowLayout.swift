import SwiftUI

/// A layout that wraps children into multiple lines, flowing left-to-right.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var firstInRow = true

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !firstInRow && rowWidth + spacing + size.width > width {
                height += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
                firstInRow = true
            } else {
                if !firstInRow { rowWidth += spacing }
                rowWidth += size.width
                rowHeight = max(rowHeight, size.height)
                firstInRow = false
            }
        }
        height += rowHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        var firstInRow = true

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !firstInRow && x + spacing + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
                firstInRow = true
            } else if !firstInRow {
                x += spacing
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
            firstInRow = false
        }
    }
}
