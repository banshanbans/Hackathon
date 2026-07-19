import XCTest
@testable import SoloShot

final class FrameSelectionEngineTests: XCTestCase {
    func testKnownPoseUsesFivePublishedWeights() {
        let input = CandidateInput(
            frameID: "frame_known",
            timestampMilliseconds: 0,
            localFilename: "known.jpg",
            metrics: FrameQualityMetrics(
                completeFraming: 1,
                targetPositionMatch: 1,
                personScaleMatch: 1,
                sharpness: 1,
                supportedPoseMatch: 1
            )
        )
        XCTAssertEqual(FrameSelectionEngine.rank([input]).first?.localScore ?? 0, 1, accuracy: 0.0001)
    }

    func testUnknownPoseRenormalizesRemainingWeightsWithoutGuessing() {
        let input = CandidateInput(
            frameID: "frame_unknown",
            timestampMilliseconds: nil,
            localFilename: "unknown.jpg",
            metrics: FrameQualityMetrics(
                completeFraming: 0.9,
                targetPositionMatch: 0.8,
                personScaleMatch: 0.7,
                sharpness: 0.6,
                supportedPoseMatch: nil
            )
        )
        let candidate = FrameSelectionEngine.rank([input])[0]
        XCTAssertEqual(candidate.localScore, (0.9 * 0.30 + 0.8 * 0.25 + 0.7 * 0.20 + 0.6 * 0.15) / 0.90, accuracy: 0.0001)
        XCTAssertTrue(candidate.reasons.contains("未知姿势未参与评分"))
    }

    func testMultiplePeopleAndMissingHeadFeetAreExplicitlyDegraded() {
        let clean = input(id: "frame_clean", people: 1, complete: true)
        let degraded = input(id: "frame_degraded", people: 2, complete: false)
        let ranked = FrameSelectionEngine.rank([degraded, clean])
        XCTAssertEqual(ranked.first?.id, "frame_clean")
        XCTAssertTrue(ranked.last?.reasons.contains("画面中有多个人") == true)
    }

    func testVideoCandidatesAreSpacedAndCoverStartMiddleEnd() {
        let inputs = (0 ..< 10).map { index in
            CandidateInput(
                frameID: "frame_\(index)",
                timestampMilliseconds: index * 500,
                localFilename: "\(index).jpg",
                metrics: FrameQualityMetrics(
                    completeFraming: 1,
                    targetPositionMatch: Double(index) / 10,
                    personScaleMatch: 1,
                    sharpness: 1,
                    supportedPoseMatch: 1
                )
            )
        }
        let selected = FrameSelectionEngine.temporallySpaced(inputs)
        XCTAssertLessThanOrEqual(selected.count, 6)
        XCTAssertEqual(selected.first?.timestampMilliseconds, 0)
        XCTAssertEqual(selected.last?.timestampMilliseconds, 4_500)
        XCTAssertTrue(selected.contains { $0.timestampMilliseconds == 2_500 })
        for pair in zip(selected, selected.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                (pair.1.timestampMilliseconds ?? 0) - (pair.0.timestampMilliseconds ?? 0),
                400
            )
        }
    }

    private func input(id: String, people: Int, complete: Bool) -> CandidateInput {
        CandidateInput(
            frameID: id,
            timestampMilliseconds: nil,
            localFilename: "\(id).jpg",
            metrics: FrameQualityMetrics(
                completeFraming: complete ? 1 : 0.4,
                targetPositionMatch: 1,
                personScaleMatch: 1,
                sharpness: 1,
                supportedPoseMatch: 1,
                personCount: people,
                headAndFeetVisible: complete,
                averageConfidence: 0.9
            )
        )
    }
}
