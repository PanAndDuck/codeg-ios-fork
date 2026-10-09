import SwiftUI
import UIKit

/// All frames use the same coordinate space, including partially visible rows.
/// Keep a leading pixel rather than a fraction of a row whose height can change.
struct TranscriptReadingAnchor {
    struct Row: Equatable {
        let turnID: String
        let rowID: String
        let frame: CGRect
    }

    let turnID: String
    let rowID: String
    let offsetY: CGFloat

    static func capture(rows: [Row], viewport: CGRect) -> Self? {
        guard let row = rows.filter({ $0.frame.maxY > viewport.minY && $0.frame.minY < viewport.maxY })
            .min(by: { $0.frame.minY < $1.frame.minY }) else { return nil }
        return Self(turnID: row.turnID, rowID: row.rowID, offsetY: row.frame.minY - viewport.minY)
    }

    func adjustment(rowMinY: CGFloat, viewportMinY: CGFloat) -> CGFloat {
        rowMinY - viewportMinY - offsetY
    }
}

/// SwiftUI reports actual row placement; UIKit only applies the pixel delta.
/// A UIView inside a recycled List cell can retain an old frame, so it must not
/// be used to measure the row. ScrollViewReader realizes a missing stable ID.
@MainActor
final class TranscriptAnchorController {
    private weak var scrollView: UIScrollView?
    private var rows: [String: TranscriptReadingAnchor.Row] = [:]
    private var anchor: TranscriptReadingAnchor?
    private var restoreScheduled = false
    private var realizeRow: ((String) -> Void)?
    private var realizationFrames: CADisplayLink?
    var isPreserving: Bool { anchor != nil }

    func attach(_ scroll: UIScrollView) {
        if let scrollView, scrollView !== scroll { cancel() }
        scrollView = scroll
    }

    func updateRows(_ rows: [String: TranscriptReadingAnchor.Row]) {
        self.rows = rows
        layoutChanged()
    }

    private func viewport(in scroll: UIScrollView) -> CGRect {
        scroll.convert(scroll.bounds, to: nil).inset(by: scroll.adjustedContentInset)
    }

    func capture() {
        // A header can shrink while already at the top clamp. Its pixel cannot
        // be restored until the prepend creates room, so retain that intent.
        // User scrolling cancels it and the pre-commit capture then samples anew.
        guard anchor == nil else { return }
        guard let scroll = scrollView else { cancel(); return }
        anchor = TranscriptReadingAnchor.capture(rows: Array(rows.values), viewport: viewport(in: scroll))
    }

    func cancel() {
        anchor = nil
        realizeRow = nil
        stopRealizing()
    }

    func restore(using proxy: ScrollViewProxy) {
        restore { id in
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(id, anchor: .top) }
        }
    }

    func restore(realizeRow: @escaping (String) -> Void) {
        self.realizeRow = realizeRow
        layoutChanged()
    }

    /// Coalesce actual row-geometry notifications and leave SwiftUI's layout
    /// pass before changing the offset. No fixed delay or estimated height delta.
    private func layoutChanged() {
        guard anchor != nil, !restoreScheduled else { return }
        restoreScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restoreScheduled = false
            self.restoreAfterLayout()
        }
    }

    private func restoreAfterLayout() {
        guard let anchor, let scroll = scrollView else { return }
        guard let row = rows[anchor.rowID], row.turnID == anchor.turnID else {
            // List may report another intermediate layout before its batch
            // insertion has committed. Keep the ID request until the row returns.
            if !rows.isEmpty { realizeRow?(anchor.rowID) }
            if realizationFrames == nil, realizeRow != nil {
                // A List batch can ignore scrollTo and then emit no more geometry
                // until something scrolls. Retry on layout frames until the stable
                // row actually appears, rather than assuming a delay was enough.
                let frames = CADisplayLink(target: RealizationTick(owner: self), selector: #selector(RealizationTick.tick))
                realizationFrames = frames
                frames.add(to: .main, forMode: .common)
            }
            return
        }
        stopRealizing()
        let delta = anchor.adjustment(rowMinY: row.frame.minY, viewportMinY: viewport(in: scroll).minY)
        let insets = scroll.adjustedContentInset
        let maximum = max(-insets.top, scroll.contentSize.height - scroll.bounds.height + insets.bottom)
        let y = min(max(-insets.top, scroll.contentOffset.y + delta), maximum)
        guard abs(scroll.contentOffset.y - y) > 0.5 else { return }
        UIView.performWithoutAnimation {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
        }
    }

    private func stopRealizing() {
        realizationFrames?.invalidate()
        realizationFrames = nil
    }

    @MainActor
    private final class RealizationTick: NSObject {
        weak var owner: TranscriptAnchorController?
        init(owner: TranscriptAnchorController) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.restoreAfterLayout()
        }
    }
}

/// Locates only the enclosing public UIScrollView. It does not replace its
/// delegate/data source, inspect private view types, or measure recycled cells.
struct TranscriptScrollViewProbe: UIViewRepresentable {
    let controller: TranscriptAnchorController

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ view: Probe, context: Context) {
        view.controller = controller
        view.attach()
    }

    final class Probe: UIView {
        weak var controller: TranscriptAnchorController?

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func attach() {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { controller?.attach(scroll); return }
                ancestor = view.superview
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { attach() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attach()
        }
    }
}
