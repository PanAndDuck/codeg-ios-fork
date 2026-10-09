import SwiftUI
import XCTest
@testable import Codeg

final class MentionAwareTextEditorTests: XCTestCase {
    @MainActor
    func testEditorRestoresInsertionCaretAtStartMiddleAndEnd() async throws {
        let agent = try AgentIdentityFixtures.agent()
        let model = ComposeInsertModel(client: CodegClient(
            baseURL: URL(string: "http://127.0.0.1:18482")!, token: "f2-test"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (head, suffix) in [("", "AFTER"), ("👩🏽‍💻 BEFORE ", "AFTER"), ("BEFORE ", "")] {
            let state = EditorState(text: head + "@E2E" + suffix, offset: (head + "@E2E").utf16.count)
            let initial = expectation(description: "Initial caret")
            state.onCursor = { offset in
                if offset == (head + "@E2E").utf16.count {
                    state.onCursor = nil
                    initial.fulfill()
                }
            }
            let host = UIHostingController(rootView: EditorHarness(state: state))
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = host
            window.isHidden = false
            defer {
                state.onCursor = nil
                window.isHidden = true
                window.rootViewController = nil
            }
            host.view.layoutIfNeeded()
            await fulfillment(of: [initial], timeout: 2)
            state.onCursor = nil
            let view = try XCTUnwrap(findEditor(in: host.view))
            let cursor = String.Index(utf16Offset: view.selectedRange.location, in: state.text)
            let result = model.draftInsertingAgentMention(agent, to: state.text, cursor: cursor)
            let inserted = expectation(description: "Mention caret restored by updateUIView")
            state.onCursor = { offset in
                if state.text == result.draft, offset == result.cursorUTF16Offset {
                    state.onCursor = nil
                    inserted.fulfill()
                }
            }
            state.text = result.draft
            state.pendingOffset = result.cursorUTF16Offset
            await fulfillment(of: [inserted], timeout: 2)
            state.onCursor = nil
            XCTAssertEqual(view.selectedRange, NSRange(location: result.cursorUTF16Offset, length: 0))
            view.insertText("CURSOR ")
            XCTAssertEqual(state.text, head + "[@E2E scripted mock](codeg://agent/custom:e2e-mock) CURSOR " + suffix)
        }
    }

    @MainActor
    private func findEditor(in view: UIView) -> MentionAwareTextEditor.InternalTextView? {
        if let editor = view as? MentionAwareTextEditor.InternalTextView { return editor }
        for child in view.subviews {
            if let editor = findEditor(in: child) { return editor }
        }
        return nil
    }
}

@MainActor
private final class EditorState: ObservableObject {
    @Published var text: String
    @Published var pendingOffset: Int?
    var onCursor: ((Int?) -> Void)?

    init(text: String, offset: Int) {
        self.text = text
        self.pendingOffset = offset
    }
}

@MainActor
private struct EditorHarness: View {
    @ObservedObject var state: EditorState

    var body: some View {
        MentionAwareTextEditor(text: $state.text, placeholder: "Message", isFocused: false,
                               onFocusChange: { _ in }, onCursorChange: { state.onCursor?($0) },
                               pendingCursorUTF16Offset: $state.pendingOffset)
    }
}
