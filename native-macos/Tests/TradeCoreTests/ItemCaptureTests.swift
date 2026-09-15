import Foundation
import XCTest
@testable import TradeCore

final class ItemCaptureTests: XCTestCase {
    private let gameProcessID: Int32 = 42
    private let originalChangeCount = 100

    func testCopyWaitsForPhysicalKeyReleaseAndIsSentOnlyOnce() {
        var session = makeSession()

        XCTAssertEqual(pollKeys(&session, released: false, now: 10.2), .waiting)
        XCTAssertEqual(pollKeys(&session, released: false, now: 10.8), .waiting)
        XCTAssertEqual(pollKeys(&session, released: true, now: 10.9), .sendCopy)
        XCTAssertEqual(pollKeys(&session, released: true, now: 10.95), .waiting)
        XCTAssertEqual(pollKeys(&session, released: false, now: 11), .waiting)
    }

    func testLosingGameFocusBeforeKeyReleaseFailsWithoutCopying() {
        for frontmostProcessID: Int32? in [99, nil] {
            var session = makeSession()

            XCTAssertEqual(session.pollKeysReleased(
                true,
                frontmostProcessID: frontmostProcessID,
                now: 10.1,
                clipboardChangeCount: originalChangeCount
            ), .failed(.gameChanged))
            XCTAssertEqual(pollKeys(&session, released: true, now: 10.2), .waiting)
        }
    }

    func testLosingGameFocusAfterCopyRejectsEvenFreshItemText() {
        for frontmostProcessID: Int32? in [99, nil] {
            var session = makeSession()
            XCTAssertEqual(pollKeys(&session, released: true, now: 10.1), .sendCopy)

            XCTAssertEqual(session.pollClipboard(
                frontmostProcessID: frontmostProcessID,
                now: 10.2,
                changeCount: originalChangeCount + 1,
                text: englishItem
            ), .failed(.gameChanged))
            XCTAssertEqual(pollClipboard(&session, now: 10.3, changeCount: 102, text: englishItem), .waiting)
        }
    }

    func testHeldKeysReachReleaseTimeoutAndCannotLaterTriggerCopy() {
        var session = ItemCaptureSession(
            gameProcessID: gameProcessID,
            startedAt: 10,
            keyReleaseTimeout: 0.5,
            clipboardTimeout: 1
        )

        XCTAssertEqual(pollKeys(&session, released: false, now: 10.49), .waiting)
        XCTAssertEqual(pollKeys(&session, released: false, now: 10.5), .failed(.keysStillHeld))
        XCTAssertEqual(pollKeys(&session, released: true, now: 10.6), .waiting)
    }

    func testClipboardPollingBeforeCopyDoesNotCaptureExistingText() {
        var session = makeSession()

        XCTAssertEqual(pollClipboard(&session, now: 10.1, changeCount: 101, text: englishItem), .waiting)
        XCTAssertEqual(pollKeys(&session, released: true, now: 10.2), .sendCopy)
    }

    func testUnchangedClipboardWaitsEvenWhenItAlreadyContainsValidItemText() {
        var session = makeSession()
        XCTAssertEqual(pollKeys(&session, released: true, now: 10.1), .sendCopy)

        XCTAssertEqual(pollClipboard(&session, now: 10.2, changeCount: 100, text: englishItem), .waiting)
        XCTAssertEqual(pollClipboard(&session, now: 10.8, changeCount: 100, text: chineseItem), .waiting)
    }

    func testClipboardBaselineIsTakenWhenCopyIsSent() {
        var session = makeSession()
        XCTAssertEqual(pollKeys(&session, released: false, now: 10.1), .waiting)
        XCTAssertEqual(session.pollKeysReleased(
            true,
            frontmostProcessID: gameProcessID,
            now: 10.2,
            clipboardChangeCount: 105
        ), .sendCopy)

        XCTAssertEqual(pollClipboard(&session, now: 10.3, changeCount: 105, text: englishItem), .waiting)
        XCTAssertEqual(pollClipboard(&session, now: 10.4, changeCount: 106, text: chineseItem), .captured(chineseItem, changeCount: 106))
    }

    func testFreshEnglishAndChineseItemsAreCapturedWithoutChangingTheirText() {
        for item in [englishItem, chineseItem] {
            var session = makeSession()
            XCTAssertEqual(pollKeys(&session, released: true, now: 10.1), .sendCopy)

            XCTAssertEqual(pollClipboard(&session, now: 10.2, changeCount: 101, text: item), .captured(item, changeCount: 101))
            XCTAssertEqual(pollClipboard(&session, now: 10.3, changeCount: 102, text: item), .waiting)
            XCTAssertEqual(pollKeys(&session, released: true, now: 10.4), .waiting)
        }
    }

    func testFreshNonItemClipboardContentFailsInsteadOfUsingPreviousItem() {
        var session = makeSession()
        XCTAssertEqual(pollKeys(&session, released: true, now: 10.1), .sendCopy)
        XCTAssertEqual(pollClipboard(&session, now: 10.2, changeCount: 100, text: englishItem), .waiting)

        XCTAssertEqual(pollClipboard(&session, now: 10.3, changeCount: 101, text: "A freshly copied unrelated message"), .failed(.invalidItem))
        XCTAssertEqual(pollClipboard(&session, now: 10.4, changeCount: 102, text: englishItem), .waiting)
    }

    func testClearingClipboardBeforeWritingItemWaitsForText() {
        for clearedText: String? in [nil, "", " \n\t "] {
            var session = makeSession()
            XCTAssertEqual(pollKeys(&session, released: true, now: 10.1), .sendCopy)

            XCTAssertEqual(pollClipboard(&session, now: 10.2, changeCount: 101, text: clearedText), .waiting)
            XCTAssertEqual(pollClipboard(&session, now: 10.3, changeCount: 102, text: englishItem), .captured(englishItem, changeCount: 102))
        }
    }

    func testClipboardTimeoutStartsAtCopyAndNeverReturnsStaleItemText() {
        var session = ItemCaptureSession(
            gameProcessID: gameProcessID,
            startedAt: 10,
            keyReleaseTimeout: 1,
            clipboardTimeout: 0.5
        )
        XCTAssertEqual(pollKeys(&session, released: false, now: 10.6), .waiting)
        XCTAssertEqual(pollKeys(&session, released: true, now: 10.8), .sendCopy)

        XCTAssertEqual(pollClipboard(&session, now: 11.2, changeCount: 100, text: englishItem), .waiting)
        XCTAssertEqual(pollClipboard(&session, now: 11.3, changeCount: 100, text: englishItem), .failed(.clipboardTimeout))
        XCTAssertEqual(pollClipboard(&session, now: 11.4, changeCount: 101, text: englishItem), .waiting)
    }

    func testCancelBeforeOrAfterCopyIsTerminal() {
        for copyWasSent in [false, true] {
            var session = makeSession()
            if copyWasSent {
                XCTAssertEqual(pollKeys(&session, released: true, now: 10.1), .sendCopy)
            }

            XCTAssertEqual(session.cancel(), .failed(.cancelled))
            XCTAssertEqual(pollKeys(&session, released: true, now: 10.2), .waiting)
            XCTAssertEqual(pollClipboard(&session, now: 10.3, changeCount: 101, text: englishItem), .waiting)
        }
    }

    func testItemTextRecognitionSupportsEnglishAndTraditionalChinese() {
        XCTAssertTrue(ItemCaptureSession.isItemText(englishItem))
        XCTAssertTrue(ItemCaptureSession.isItemText(chineseItem))
        XCTAssertFalse(ItemCaptureSession.isItemText(""))
        XCTAssertFalse(ItemCaptureSession.isItemText("An unrelated clipboard message"))
    }

    func testClipboardRestorationIsAllowedOnlyWhileCapturedContentsRemainCurrent() {
        XCTAssertTrue(ItemCaptureSession.shouldRestoreClipboard(capturedChangeCount: 101, currentChangeCount: 101))
        XCTAssertFalse(ItemCaptureSession.shouldRestoreClipboard(capturedChangeCount: 101, currentChangeCount: 102))
        XCTAssertFalse(ItemCaptureSession.shouldRestoreClipboard(capturedChangeCount: 101, currentChangeCount: 105))
    }

    func testFocusLossAndCancellationDoNotPresentTheApp() {
        XCTAssertFalse(ItemCaptureFailure.gameChanged.shouldPresentApp)
        XCTAssertFalse(ItemCaptureFailure.cancelled.shouldPresentApp)
        for failure in [ItemCaptureFailure.keysStillHeld, .clipboardTimeout, .invalidItem, .accessibilityRequired, .eventCreationFailed] {
            XCTAssertTrue(failure.shouldPresentApp)
        }
    }

    private func makeSession() -> ItemCaptureSession {
        ItemCaptureSession(gameProcessID: gameProcessID, startedAt: 10)
    }

    private func pollKeys(_ session: inout ItemCaptureSession, released: Bool, now: TimeInterval) -> ItemCaptureDecision {
        session.pollKeysReleased(
            released,
            frontmostProcessID: gameProcessID,
            now: now,
            clipboardChangeCount: originalChangeCount
        )
    }

    private func pollClipboard(_ session: inout ItemCaptureSession, now: TimeInterval, changeCount: Int, text: String?) -> ItemCaptureDecision {
        session.pollClipboard(
            frontmostProcessID: gameProcessID,
            now: now,
            changeCount: changeCount,
            text: text
        )
    }

    private var englishItem: String {
        """
        Item Class: Stackable Currency
        Rarity: Currency
        Chaos Orb
        --------
        Stack Size: 10/20
        --------
        Reforges a rare item with new random modifiers
        """
    }

    private var chineseItem: String {
        """
        物品種類: 可堆疊通貨
        稀有度: 通貨
        混沌石
        --------
        堆疊數量: 10/20
        --------
        重鑄一件稀有物品，獲得新的隨機詞綴
        """
    }
}
