import XCTest
@testable import Codeg

final class TranscriptPagingTests: XCTestCase {
    func testRevealingRemainingLocalTailAlsoRequestsOlderHistory() {
        let page = TranscriptPaging.earlierPage(turns: turns(60), renderedStart: 10, hasEarlier: true)
        XCTAssertEqual(page.start, 0)
        XCTAssertTrue(page.fetchFromServer)
    }

    func testLegacyHistoryExpandsLocallyAndKeepsRoundBoundary() {
        let page = TranscriptPaging.earlierPage(turns: turns(400), renderedStart: 353, hasEarlier: false)
        XCTAssertEqual(page.start, 200)
        XCTAssertFalse(page.fetchFromServer)
        let last = TranscriptPaging.earlierPage(turns: turns(60), renderedStart: 10, hasEarlier: false)
        XCTAssertEqual(last.start, 0)
        XCTAssertFalse(last.fetchFromServer)
    }

    private func turns(_ count: Int) -> [MessageTurn] {
        (0..<count).map { MessageTurn(id: "\($0)", role: $0 % 5 == 0 ? .user : .assistant,
                                     blocks: [], timestamp: Date(timeIntervalSince1970: Double($0))) }
    }
}
