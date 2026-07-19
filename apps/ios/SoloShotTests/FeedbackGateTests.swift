import Foundation
import SoloShotContracts
import XCTest
@testable import SoloShot

final class FeedbackGateTests: XCTestCase {
    func testFeedbackRequiresConfirmationAndTwoSecondCooldown() {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        var gate = FeedbackGate(minimumInterval: 2)
        XCTAssertFalse(gate.shouldEmit(instruction: .moveLeft, confirmed: false, at: start))
        XCTAssertTrue(gate.shouldEmit(instruction: .moveLeft, confirmed: true, at: start))
        XCTAssertFalse(
            gate.shouldEmit(instruction: .moveRight, confirmed: true, at: start.addingTimeInterval(1.9))
        )
        XCTAssertTrue(
            gate.shouldEmit(instruction: .moveRight, confirmed: true, at: start.addingTimeInterval(2.0))
        )
    }

    func testEveryContractInstructionHasControlledChineseCopy() {
        for instruction in CurrentAlignment.InstructionCode.allCases {
            let presentation = CoachPresentation.from(instruction)
            XCTAssertFalse(presentation.text.isEmpty)
            XCTAssertLessThanOrEqual(presentation.text.count, 12)
        }
    }
}
