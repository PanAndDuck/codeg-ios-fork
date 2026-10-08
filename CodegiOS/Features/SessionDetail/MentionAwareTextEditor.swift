import SwiftUI
import UIKit

/// A growing multiline text input backed by `UITextView` — not a plain SwiftUI
/// `TextField`, which exposes no caret position. The `@`-mention popup needs
/// the actual caret to detect a live `@token` wherever it's typed, not only at
/// the end of the draft (mirrors the desktop/web composer's Tiptap-based
/// cursor-aware trigger — see `ComposeInsertModel.trailingMentionToken`).
///
/// Deliberately narrow: it reproduces just the `TextField(axis: .vertical)`
/// behavior `ComposeBar` relied on (an auto-growing 1–6 line field, a
/// placeholder, Dynamic Type, first-responder tracking) plus the one thing a
/// `TextField` can't do — report the caret position on every change.
struct MentionAwareTextEditor: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isFocused: Bool
    var onFocusChange: (Bool) -> Void
    /// Fires on every text/selection change with the caret's UTF-16 offset
    /// into `text` — `nil` selection (a range, not a single caret) reports `nil`.
    var onCursorChange: (Int?) -> Void
    /// A caret position (UTF-16 offset) to move to on the next update — set by
    /// the owner right after programmatically rewriting `text` (e.g. inserting
    /// a mention badge), consumed once. `nil` otherwise: the view keeps
    /// whatever position the user's own typing already left it at.
    @Binding var pendingCursorUTF16Offset: Int?

    var font: UIFont = .preferredFont(forTextStyle: .body)
    var minLines: Int = 1
    var maxLines: Int = 6

    func makeUIView(context: Context) -> InternalTextView {
        let view = InternalTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = font
        view.textColor = UIColor(Theme.textPrimary)
        view.tintColor = UIColor(Theme.accent)
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.adjustsFontForContentSizeCategory = true
        view.autocapitalizationType = .sentences
        view.backgroundColor = .clear
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.placeholderLabel.text = placeholder
        view.placeholderLabel.font = font
        view.placeholderLabel.textColor = UIColor(Theme.textTertiary)
        return view
    }

    func updateUIView(_ uiView: InternalTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.isUpdatingView = true
        defer { context.coordinator.isUpdatingView = false }
        let textChanged = uiView.text != text
        if textChanged {
            uiView.text = text
        }
        uiView.placeholderLabel.isHidden = !text.isEmpty
        if uiView.font != font {
            uiView.font = font
            uiView.placeholderLabel.font = font
        }

        if let offset = pendingCursorUTF16Offset {
            let ns = text as NSString
            let clamped = max(0, min(offset, ns.length))
            uiView.selectedRange = NSRange(location: clamped, length: 0)
            DispatchQueue.main.async { pendingCursorUTF16Offset = nil }
        }

        if textChanged || pendingCursorUTF16Offset != nil {
            let updatedText = uiView.text
            let updatedRange = uiView.selectedRange
            DispatchQueue.main.async {
                guard uiView.text == updatedText, uiView.selectedRange == updatedRange else { return }
                context.coordinator.reportCursor(uiView)
            }
        }

        if isFocused, !uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        } else if !isFocused, uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// A bare `UITextView` gains a placeholder label as a subview (there's no
    /// native placeholder), sized to the same text-container inset the real
    /// text uses so it lines up exactly.
    final class InternalTextView: UITextView {
        let placeholderLabel = UILabel()

        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            addSubview(placeholderLabel)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            placeholderLabel.frame = CGRect(
                x: textContainerInset.left + textContainer.lineFragmentPadding,
                y: textContainerInset.top,
                width: bounds.width - textContainerInset.left - textContainerInset.right,
                height: font?.lineHeight ?? 20
            )
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MentionAwareTextEditor
        var isUpdatingView = false
        init(_ parent: MentionAwareTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdatingView else { return }
            parent.text = textView.text
            reportCursor(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // UIKit can report the new selection before the corresponding text
            // change. Publish that caret only once the binding contains its text.
            guard textView.text == parent.text else { return }
            reportCursor(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            guard !isUpdatingView else { return }
            parent.onFocusChange(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard !isUpdatingView else { return }
            parent.onFocusChange(false)
        }

        func reportCursor(_ textView: UITextView) {
            guard !isUpdatingView else { return }
            let range = textView.selectedRange
            parent.onCursorChange(range.length == 0 ? range.location : nil)
        }
    }
}

/// Intrinsic-size bridge: SwiftUI asks for this on every layout pass, so the
/// field grows/shrinks between `minLines`/`maxLines` as text wraps — the
/// `UIViewRepresentable` counterpart of `TextField`'s `.lineLimit(1...6)`.
extension MentionAwareTextEditor {
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: InternalTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        let textFont = uiView.font ?? font
        // TextKit includes leading in its line fragments; lineHeight alone
        // clips the sixth line and enables scrolling too early.
        let lineHeight = textFont.lineHeight + textFont.leading
        let minHeight = (lineHeight * CGFloat(minLines)).rounded(.up)
        let maxHeight = (lineHeight * CGFloat(maxLines)).rounded(.up)
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        uiView.isScrollEnabled = fitting.height > maxHeight
        let clamped = min(max(fitting.height, minHeight), maxHeight)
        return CGSize(width: width, height: clamped.rounded(.up))
    }
}
