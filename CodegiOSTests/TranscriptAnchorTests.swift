import XCTest
import UIKit
@testable import Codeg

final class TranscriptAnchorTests: XCTestCase {
    @MainActor
    func testTopClampRetainsPixelIntentThroughHeaderShrinkAndPrepend() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentInset.top = 116
        scroll.contentSize = CGSize(width: 402, height: 20000)
        scroll.contentOffset.y = -116
        window.addSubview(scroll)
        let row = UIView(frame: CGRect(x: 14, y: 34, width: 372, height: 96))
        scroll.addSubview(row)
        let controller = TranscriptAnchorController()
        controller.attach(scroll)
        func updateRows() {
            controller.updateRows(["first": .init(turnID: "first", rowID: "first",
                                                  frame: row.convert(row.bounds, to: window))])
        }
        updateRows()
        controller.capture()
        let before = row.convert(row.bounds, to: window).minY
        row.frame.origin.y -= 28
        updateRows()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(scroll.contentOffset.y, -116, "Header shrink cannot scroll beyond the top clamp")
        controller.capture()
        row.frame.origin.y += 9000
        updateRows()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(row.convert(row.bounds, to: window).minY, before, accuracy: 0.5)
        controller.cancel()
    }

    @MainActor
    func testMissingRowRealizationSurvivesIntermediateListLayout() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentSize = CGSize(width: 402, height: 20000)
        window.addSubview(scroll)
        let controller = TranscriptAnchorController()
        controller.attach(scroll)
        let row = TranscriptReadingAnchor.Row(turnID: "first", rowID: "first#1",
                                               frame: CGRect(x: 14, y: 34, width: 372, height: 96))
        controller.updateRows([row.rowID: row])
        controller.capture()
        controller.updateRows(["temporary": .init(turnID: "temporary", rowID: "temporary", frame: row.frame)])
        let retried = expectation(description: "Realize again after an ignored intermediate layout")
        var attempts = 0
        controller.restore { id in
            XCTAssertEqual(id, row.rowID)
            attempts += 1
            if attempts == 2 {
                controller.updateRows([row.rowID: row])
                retried.fulfill()
            }
        }
        await fulfillment(of: [retried], timeout: 2)
        controller.cancel()
        let completedAttempts = attempts
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(attempts, completedAttempts, "Cancellation stops frame retries")
    }

    @MainActor
    func testLayoutCorrectionAndUserCancellationOnRealScrollView() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentInset = UIEdgeInsets(top: 116, left: 0, bottom: 132, right: 0)
        scroll.contentSize = CGSize(width: 402, height: 20000)
        window.addSubview(scroll)
        let marker = UIView()
        marker.frame = CGRect(x: 14, y: 150, width: 372, height: 96)
        scroll.addSubview(marker)
        let controller = TranscriptAnchorController()
        controller.attach(scroll)
        func updateRows() {
            controller.updateRows(["acp-82": .init(turnID: "acp-82", rowID: "acp-82",
                                                  frame: marker.convert(marker.bounds, to: window))])
        }
        updateRows()
        controller.capture()
        let before = marker.convert(marker.bounds, to: window).minY
        marker.frame.origin.y += 9000
        updateRows()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(marker.convert(marker.bounds, to: window).minY, before, accuracy: 0.5)
        let offset = scroll.contentOffset.y
        controller.cancel()
        marker.frame.origin.y += 200
        updateRows()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(scroll.contentOffset.y, offset, "A new user scroll cancels the old reading anchor")
    }

    func testFirstVisibleRowIncludesPartiallyClippedRowAndExcludesInsets() throws {
        let anchor = try XCTUnwrap(TranscriptReadingAnchor.capture(rows: [
            .init(turnID: "hidden", rowID: "hidden", frame: CGRect(x: 0, y: 20, width: 300, height: 60)),
            .init(turnID: "first", rowID: "first#1", frame: CGRect(x: 0, y: 90, width: 300, height: 80)),
            .init(turnID: "next", rowID: "next", frame: CGRect(x: 0, y: 170, width: 300, height: 90))
        ], viewport: CGRect(x: 0, y: 116, width: 300, height: 600)))
        XCTAssertEqual(anchor.turnID, "first")
        XCTAssertEqual(anchor.rowID, "first#1")
        XCTAssertEqual(anchor.offsetY, -26)
        // Prepending moves the same row to content y=1090. Keep its 26pt clip.
        XCTAssertEqual(anchor.adjustment(rowMinY: 1090, viewportMinY: 116), 1000)
    }

    func testPreservesExactPixelOffsetWithInsetsAndChangedRowHeight() throws {
        let anchor = try XCTUnwrap(TranscriptReadingAnchor.capture(rows: [
            .init(turnID: "acp-82", rowID: "acp-82", frame: CGRect(x: 14, y: 150, width: 372, height: 96))
        ], viewport: CGRect(x: 0, y: 116, width: 402, height: 626)))
        XCTAssertEqual(anchor.offsetY, 34)
        // Height is intentionally irrelevant: restore the row's leading pixel.
        XCTAssertEqual(anchor.adjustment(rowMinY: 9150, viewportMinY: 116), 9000)
        XCTAssertEqual(anchor.adjustment(rowMinY: 9150, viewportMinY: 140), 8976)
    }

    func testEmptyOrOffscreenRowsCannotBecomeAnchor() {
        let viewport = CGRect(x: 0, y: 100, width: 300, height: 600)
        XCTAssertNil(TranscriptReadingAnchor.capture(rows: [], viewport: viewport))
        XCTAssertNil(TranscriptReadingAnchor.capture(rows: [
            .init(turnID: "above", rowID: "above", frame: CGRect(x: 0, y: 0, width: 300, height: 100)),
            .init(turnID: "below", rowID: "below", frame: CGRect(x: 0, y: 700, width: 300, height: 80))
        ], viewport: viewport))
    }

    @MainActor
    func testPrependKeepsVisibleTurnAndPartIdentityAcrossInitialRenderWindow() throws {
        let turns = (0..<120).map { index in
            MessageTurn(id: "turn-\(index)", role: index.isMultiple(of: 2) ? .user : .assistant,
                        blocks: [.text("row \(index)")], timestamp: Date(timeIntervalSince1970: Double(index)))
        }
        let initial = TranscriptTimeline.buildPersisted(turns: Array(turns.suffix(50)), pending: [],
                                                        agent: .claudeCode, suppressInFlight: false)
        let expanded = TranscriptTimeline.buildPersisted(turns: turns, pending: [],
                                                         agent: .claudeCode, suppressInFlight: false)
        XCTAssertEqual(initial.first?.id, "turn-70")
        let visible = try XCTUnwrap(initial.first { $0.id == "turn-71#0" })
        XCTAssertEqual(visible.turnID, "turn-71")
        XCTAssertEqual(expanded.first { $0.id == visible.id }?.turnID, visible.turnID)
    }
}
