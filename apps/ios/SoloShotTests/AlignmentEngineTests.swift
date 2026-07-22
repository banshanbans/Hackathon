import Foundation
import SoloShotContracts
import XCTest
@testable import SoloShot

final class AlignmentEngineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    func testInstructionPriorityCoversPeopleCompletenessScaleAndPosition() {
        var engine = makeEngine()
        XCTAssertEqual(confirm(&engine, observations: []).alignment.instructionCode, .noPerson)

        engine = makeEngine()
        let two = [makePerson(), makePerson(id: UUID())]
        XCTAssertEqual(confirm(&engine, observations: two).alignment.instructionCode, .multiplePeople)

        engine = makeEngine()
        XCTAssertEqual(
            confirm(&engine, observations: [makePerson(includeFeet: false)]).alignment.instructionCode,
            .feetOutside
        )

        engine = makeEngine()
        XCTAssertEqual(
            confirm(&engine, observations: [makePerson(rect: NormalizedRect(x: 0.42, y: 0.4, width: 0.16, height: 0.3))])
                .alignment.instructionCode,
            .moveForward
        )

        engine = makeEngine()
        XCTAssertEqual(
            confirm(&engine, observations: [makePerson(rect: NormalizedRect(x: 0.1, y: 0.25, width: 0.3, height: 0.6))])
                .alignment.instructionCode,
            .moveRight
        )
    }

    func testReadyRequiresDurationSamplesAndUsesCompositionFallbackForUnknownTemplate() {
        var target = makeTarget()
        target = ImportedTargetLayout(
            centerX: target.centerX,
            centerY: target.centerY,
            width: target.width,
            height: target.height,
            headPoint: target.headPoint,
            footLineY: target.footLineY,
            bodyDirection: target.bodyDirection,
            poseTemplate: "provider_defined_unknown_pose"
        )
        var engine = AlignmentEngine(target: target, startedAt: start)
        let person = makePerson()
        for offset in [0.0, 0.1, 0.2, 1.2, 1.3] {
            let result = engine.process(observations: [person], at: start.addingTimeInterval(offset))
            XCTAssertFalse(result.alignment.readyToCapture)
        }
        let ready = engine.process(observations: [person], at: start.addingTimeInterval(1.4))
        XCTAssertTrue(ready.alignment.readyToCapture)
        XCTAssertEqual(ready.completionMode, .compositionOnly)
        XCTAssertFalse(ready.poseCheckSupported)
    }

    func testNormalizedIoUAndEightyPercentEntryBoundary() {
        let targetRect = makeTarget().rect
        let eightyPercentRect = centeredRect(width: targetRect.width * 0.80)
        let belowEntryRect = centeredRect(width: targetRect.width * 0.799)
        XCTAssertEqual(targetRect.intersectionOverUnion(with: targetRect), 1, accuracy: 0.000_001)
        XCTAssertEqual(targetRect.intersectionOverUnion(with: eightyPercentRect), 0.80, accuracy: 0.000_001)

        var passingEngine = makeEngine()
        var passing: AlignmentDecision?
        for offset in [0.0, 0.1, 0.2, 1.2, 1.3, 1.4] {
            passing = passingEngine.process(
                observations: [makePerson(rect: eightyPercentRect)],
                at: start.addingTimeInterval(offset)
            )
        }
        XCTAssertEqual(passing?.overlapRatio ?? 0, 0.80, accuracy: 0.000_001)
        XCTAssertTrue(passing?.alignment.readyToCapture == true)

        var failingEngine = makeEngine()
        var failing: AlignmentDecision?
        for offset in [0.0, 0.1, 0.2, 1.2, 1.3, 1.4, 2.0] {
            failing = failingEngine.process(
                observations: [makePerson(rect: belowEntryRect)],
                at: start.addingTimeInterval(offset)
            )
        }
        XCTAssertLessThan(failing?.overlapRatio ?? 1, 0.80)
        XCTAssertFalse(failing?.alignment.readyToCapture == true)
    }

    func testEntryStabilityResetsBelowEightyPercent() {
        var engine = makeEngine()
        let passing = makePerson(rect: centeredRect(width: makeTarget().width * 0.80))
        let failing = makePerson(rect: centeredRect(width: makeTarget().width * 0.799))
        for offset in [0.0, 0.1, 0.8] {
            _ = engine.process(observations: [passing], at: start.addingTimeInterval(offset))
        }
        let reset = engine.process(observations: [failing], at: start.addingTimeInterval(1.0))
        XCTAssertEqual(reset.stableDuration, 0)

        var result = reset
        for offset in [1.1, 1.2, 2.2] {
            result = engine.process(observations: [passing], at: start.addingTimeInterval(offset))
        }
        XCTAssertFalse(result.alignment.readyToCapture)
        for offset in [2.3, 2.4, 2.5, 2.6] {
            result = engine.process(observations: [passing], at: start.addingTimeInterval(offset))
        }
        XCTAssertTrue(result.alignment.readyToCapture)
    }

    func testCountdownUsesSeventyPercentExitThreshold() {
        let target = makeTarget()
        var boundaryEngine = makeEngine()
        let boundary = boundaryEngine.process(
            observations: [makePerson(rect: centeredRect(width: target.width * 0.70))],
            at: start
        )
        XCTAssertEqual(boundary.overlapRatio, 0.70, accuracy: 0.000_001)
        XCTAssertTrue(boundary.countdownStillValid)

        var belowEngine = makeEngine()
        let below = belowEngine.process(
            observations: [makePerson(rect: centeredRect(width: target.width * 0.699))],
            at: start
        )
        XCTAssertFalse(below.countdownStillValid)
    }

    func testCountdownRejectsPeopleCompletenessAndCompositionFailures() {
        var emptyEngine = makeEngine()
        XCTAssertFalse(emptyEngine.process(observations: [], at: start).countdownStillValid)

        var multipleEngine = makeEngine()
        XCTAssertFalse(multipleEngine.process(
            observations: [makePerson(), makePerson(id: UUID())],
            at: start
        ).countdownStillValid)

        var incompleteEngine = makeEngine()
        XCTAssertFalse(incompleteEngine.process(
            observations: [makePerson(includeFeet: false)],
            at: start
        ).countdownStillValid)

        var scaleEngine = makeEngine()
        XCTAssertFalse(scaleEngine.process(
            observations: [makePerson(rect: NormalizedRect(x: 0.42, y: 0.4, width: 0.16, height: 0.3))],
            at: start
        ).countdownStillValid)
    }

    func testKnownTemplateCanReachVerifiedAndManualFallbackAppearsAfterFiveSeconds() {
        var engine = makeEngine()
        let person = makePerson()
        var result = engine.process(observations: [person], at: start)
        for offset in [0.1, 0.2, 1.2, 1.3, 1.4] {
            result = engine.process(observations: [person], at: start.addingTimeInterval(offset))
        }
        XCTAssertEqual(result.completionMode, .verified)
        XCTAssertTrue(result.instructionConfirmed)

        var emptyEngine = makeEngine()
        let early = emptyEngine.process(observations: [], at: start.addingTimeInterval(4.9))
        let late = emptyEngine.process(observations: [], at: start.addingTimeInterval(5.0))
        XCTAssertFalse(early.manualReadyAvailable)
        XCTAssertTrue(late.manualReadyAvailable)
        XCTAssertEqual(emptyEngine.manualCompletion().completionMode, .manual)
    }

    func testManualFallbackRequiresFiveContinuousSecondsWithoutUsablePerson() {
        var engine = makeEngine()
        XCTAssertFalse(engine.process(observations: [], at: start.addingTimeInterval(4.9)).manualReadyAvailable)
        _ = engine.process(observations: [makePerson()], at: start.addingTimeInterval(5.0))
        XCTAssertFalse(engine.process(observations: [], at: start.addingTimeInterval(5.1)).manualReadyAvailable)
        XCTAssertFalse(engine.process(observations: [], at: start.addingTimeInterval(10.0)).manualReadyAvailable)
        XCTAssertTrue(engine.process(observations: [], at: start.addingTimeInterval(10.1)).manualReadyAvailable)
    }

    func testHysteresisKeepsCenteredInsideExitThreshold() {
        var engine = makeEngine()
        _ = engine.process(observations: [makePerson()], at: start)
        let shifted = makePerson(rect: NormalizedRect(x: 0.37, y: 0.25, width: 0.30, height: 0.60))
        let result = engine.process(observations: [shifted], at: start.addingTimeInterval(0.1))
        XCTAssertEqual(result.alignment.positionStatus, .centered)
        XCTAssertTrue(result.countdownStillValid)
    }

    func testDecisionEnginePerformanceIsWellBelowRealtimeBudget() {
        measure {
            var engine = makeEngine()
            for index in 0 ..< 1_000 {
                _ = engine.process(
                    observations: [makePerson()],
                    at: start.addingTimeInterval(Double(index) * 0.1)
                )
            }
        }
    }

    private func confirm(
        _ engine: inout AlignmentEngine,
        observations: [PersonObservation]
    ) -> AlignmentDecision {
        var result = engine.process(observations: observations, at: start)
        result = engine.process(observations: observations, at: start.addingTimeInterval(0.1))
        result = engine.process(observations: observations, at: start.addingTimeInterval(0.2))
        return result
    }

    private func makeEngine() -> AlignmentEngine {
        AlignmentEngine(target: makeTarget(), startedAt: start)
    }

    private func makeTarget() -> ImportedTargetLayout {
        ImportedTargetLayout(
            centerX: 0.5,
            centerY: 0.55,
            width: 0.30,
            height: 0.60,
            headPoint: NormalizedPoint(x: 0.5, y: 0.25),
            footLineY: 0.85,
            bodyDirection: "front",
            poseTemplate: "doorway_crossed_legs"
        )
    }

    private func makePerson(
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        rect: NormalizedRect = NormalizedRect(x: 0.35, y: 0.25, width: 0.30, height: 0.60),
        includeFeet: Bool = true
    ) -> PersonObservation {
        var joints: [BodyJoint: PoseJoint] = [
            .nose: PoseJoint(point: NormalizedPoint(x: rect.center.x, y: rect.y + 0.04), confidence: 0.95),
            .neck: PoseJoint(point: NormalizedPoint(x: rect.center.x, y: rect.y + 0.12), confidence: 0.95),
            .leftShoulder: PoseJoint(point: NormalizedPoint(x: rect.center.x - 0.06, y: rect.y + 0.15), confidence: 0.9),
            .rightShoulder: PoseJoint(point: NormalizedPoint(x: rect.center.x + 0.06, y: rect.y + 0.15), confidence: 0.9),
            .leftWrist: PoseJoint(point: NormalizedPoint(x: rect.center.x - 0.08, y: rect.y + 0.38), confidence: 0.9),
            .rightWrist: PoseJoint(point: NormalizedPoint(x: rect.center.x + 0.08, y: rect.y + 0.38), confidence: 0.9),
            .leftHip: PoseJoint(point: NormalizedPoint(x: rect.center.x - 0.04, y: rect.y + 0.38), confidence: 0.9),
            .rightHip: PoseJoint(point: NormalizedPoint(x: rect.center.x + 0.04, y: rect.y + 0.38), confidence: 0.9),
            .leftKnee: PoseJoint(point: NormalizedPoint(x: rect.center.x - 0.04, y: rect.y + 0.48), confidence: 0.9),
            .rightKnee: PoseJoint(point: NormalizedPoint(x: rect.center.x + 0.04, y: rect.y + 0.48), confidence: 0.9),
        ]
        if includeFeet {
            joints[.leftAnkle] = PoseJoint(
                point: NormalizedPoint(x: rect.center.x - 0.04, y: rect.maxY - 0.01),
                confidence: 0.9
            )
            joints[.rightAnkle] = PoseJoint(
                point: NormalizedPoint(x: rect.center.x + 0.04, y: rect.maxY - 0.01),
                confidence: 0.9
            )
        }
        return PersonObservation(
            id: id,
            joints: joints,
            boundingBox: rect,
            confidence: 0.9,
            observedAt: start
        )
    }

    private func centeredRect(width: Double) -> NormalizedRect {
        let target = makeTarget()
        return NormalizedRect(
            x: target.centerX - width / 2,
            y: target.centerY - target.height / 2,
            width: width,
            height: target.height
        )
    }
}
