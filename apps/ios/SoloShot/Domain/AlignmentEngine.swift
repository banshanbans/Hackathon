import Foundation
import SoloShotContracts

struct AlignmentEngine: Sendable {
    private struct PoseEvaluation {
        let status: CurrentAlignment.PoseStatus
        let instruction: CurrentAlignment.InstructionCode?
        let supported: Bool
    }

    private let target: ImportedTargetLayout
    private let configuration: AlignmentConfiguration
    private var candidateInstruction: CurrentAlignment.InstructionCode?
    private var candidateCount = 0
    private var confirmedInstruction: CurrentAlignment.InstructionCode?
    private var positionWasCentered = false
    private var scaleWasCorrect = false
    private var alignedSince: Date?
    private var alignedSamples = 0
    private var noUsablePersonSince: Date?

    init(
        target: ImportedTargetLayout,
        configuration: AlignmentConfiguration = .production,
        startedAt: Date = Date()
    ) {
        self.target = target
        self.configuration = configuration
        noUsablePersonSince = startedAt
    }

    mutating func process(
        observations: [PersonObservation],
        at now: Date = Date()
    ) -> AlignmentDecision {
        let latencyStart = ProcessInfo.processInfo.systemUptime
        let credible = observations.filter { $0.confidence >= configuration.crediblePersonConfidence }
        let selected = selectPerson(from: credible)
        if selected == nil {
            noUsablePersonSince = noUsablePersonSince ?? now
        } else {
            noUsablePersonSince = nil
        }

        var personDetected = !credible.isEmpty
        var multiplePeople = credible.count > 1
        var fullBodyVisible = false
        var positionStatus = CurrentAlignment.PositionStatus.unknown
        var scaleStatus = CurrentAlignment.ScaleStatus.unknown
        var poseStatus = CurrentAlignment.PoseStatus.unknown
        var rawInstruction = CurrentAlignment.InstructionCode.noPerson
        var rawCompletionMode: AlignmentCompletionMode?
        var poseSupported = false
        var stabilityScore = 0.0
        var overlapRatio = 0.0
        var countdownStillValid = false

        if multiplePeople {
            rawInstruction = .multiplePeople
            resetAlignedState()
        } else if let person = selected {
            personDetected = true
            multiplePeople = false
            let headVisible = person.joint(.nose, minimumConfidence: configuration.jointConfidence) != nil
                || person.joint(.neck, minimumConfidence: configuration.jointConfidence) != nil
            let feetVisible = person.joint(.leftAnkle, minimumConfidence: configuration.jointConfidence) != nil
                && person.joint(.rightAnkle, minimumConfidence: configuration.jointConfidence) != nil
            fullBodyVisible = headVisible && feetVisible

            if !headVisible {
                rawInstruction = .headOutside
                resetAlignedState()
            } else if !feetVisible {
                rawInstruction = .feetOutside
                resetAlignedState()
            } else {
                let targetRect = target.rect
                overlapRatio = person.boundingBox.intersectionOverUnion(with: targetRect)
                let heightError = abs(person.boundingBox.height - targetRect.height) / max(targetRect.height, 0.001)
                let heightTolerance = scaleWasCorrect
                    ? configuration.heightExitTolerance
                    : configuration.heightEnterTolerance
                if heightError <= heightTolerance {
                    scaleWasCorrect = true
                    scaleStatus = .correct
                } else {
                    scaleWasCorrect = false
                    scaleStatus = person.boundingBox.height < targetRect.height ? .moveForward : .moveBackward
                    rawInstruction = person.boundingBox.height < targetRect.height ? .moveForward : .moveBackward
                    resetAlignedState()
                }

                if scaleWasCorrect {
                    let horizontalError = person.boundingBox.center.x - targetRect.center.x
                    let horizontalTolerance = positionWasCentered
                        ? configuration.horizontalExitTolerance
                        : configuration.horizontalEnterTolerance
                    if abs(horizontalError) <= horizontalTolerance {
                        positionWasCentered = true
                        positionStatus = .centered
                    } else {
                        positionWasCentered = false
                        if horizontalError < 0 {
                            positionStatus = .moveRight
                            rawInstruction = .moveRight
                        } else {
                            positionStatus = .moveLeft
                            rawInstruction = .moveLeft
                        }
                        resetAlignedState()
                    }
                }

                if scaleWasCorrect, positionWasCentered {
                    let pose = evaluatePose(person)
                    poseStatus = pose.status
                    poseSupported = pose.supported
                    if let instruction = pose.instruction {
                        rawInstruction = instruction
                        resetAlignedState()
                    } else {
                        countdownStillValid = overlapRatio >= configuration.overlapExitThreshold
                        if overlapRatio >= configuration.overlapEnterThreshold {
                            if alignedSince == nil {
                                alignedSince = now
                                alignedSamples = 1
                            } else {
                                alignedSamples += 1
                            }
                            let duration = now.timeIntervalSince(alignedSince ?? now)
                            let isReady = alignedSamples >= configuration.readyMinimumSamples
                                && duration >= configuration.readyMinimumDuration
                            rawInstruction = isReady ? .readyToCapture : .holdStill
                            rawCompletionMode = isReady ? (pose.supported ? .verified : .compositionOnly) : nil
                        } else {
                            rawInstruction = overlapCorrection(person: person, targetRect: targetRect)
                            applyOverlapCorrectionStatus(
                                rawInstruction,
                                positionStatus: &positionStatus,
                                scaleStatus: &scaleStatus
                            )
                            resetAlignedState()
                        }
                    }
                }

                let horizontalScore = 1 - min(
                    1,
                    abs(person.boundingBox.center.x - targetRect.center.x)
                        / max(configuration.horizontalExitTolerance, 0.001)
                )
                let heightScore = 1 - min(
                    1,
                    heightError / max(configuration.heightExitTolerance, 0.001)
                )
                stabilityScore = max(0, min(1, (horizontalScore + heightScore) / 2))
            }
        } else {
            resetAlignedState()
        }

        let instructionConfirmed = stabilize(rawInstruction)
        let displayedInstruction = confirmedInstruction ?? rawInstruction
        let completionMode = displayedInstruction == .readyToCapture && instructionConfirmed
            ? rawCompletionMode
            : nil
        let alignment = CurrentAlignment(
            schemaVersion: ._10,
            personDetected: personDetected,
            multiplePeople: multiplePeople,
            fullBodyVisible: fullBodyVisible,
            positionStatus: positionStatus,
            scaleStatus: scaleStatus,
            poseStatus: poseStatus,
            instructionCode: displayedInstruction,
            readyToCapture: completionMode != nil,
            stabilityScore: stabilityScore
        )
        return AlignmentDecision(
            alignment: alignment,
            selectedPerson: selected,
            overlapRatio: overlapRatio,
            countdownStillValid: countdownStillValid,
            stableDuration: alignedSince.map { now.timeIntervalSince($0) } ?? 0,
            completionMode: completionMode,
            manualReadyAvailable: selected == nil
                && now.timeIntervalSince(noUsablePersonSince ?? now) >= configuration.manualFallbackDelay,
            poseCheckSupported: poseSupported,
            instructionConfirmed: instructionConfirmed,
            latencyMilliseconds: (ProcessInfo.processInfo.systemUptime - latencyStart) * 1_000
        )
    }

    mutating func manualCompletion(at now: Date = Date()) -> AlignmentDecision {
        confirmedInstruction = .readyToCapture
        candidateInstruction = .readyToCapture
        candidateCount = configuration.instructionConfirmationSamples
        return AlignmentDecision(
            alignment: CurrentAlignment(
                schemaVersion: ._10,
                personDetected: false,
                multiplePeople: false,
                fullBodyVisible: false,
                positionStatus: .unknown,
                scaleStatus: .unknown,
                poseStatus: .unknown,
                instructionCode: .readyToCapture,
                readyToCapture: true,
                stabilityScore: 0
            ),
            selectedPerson: nil,
            overlapRatio: 0,
            countdownStillValid: true,
            stableDuration: 0,
            completionMode: .manual,
            manualReadyAvailable: true,
            poseCheckSupported: false,
            instructionConfirmed: true,
            latencyMilliseconds: 0
        )
    }

    private func selectPerson(from observations: [PersonObservation]) -> PersonObservation? {
        observations.max { lhs, rhs in
            let lhsScore = selectionScore(lhs)
            let rhsScore = selectionScore(rhs)
            if lhsScore == rhsScore {
                return lhs.confidence < rhs.confidence
            }
            return lhsScore < rhsScore
        }
    }

    private func selectionScore(_ person: PersonObservation) -> Double {
        let completeJoints = BodyJoint.allCases.reduce(into: 0) { count, joint in
            if person.joint(joint, minimumConfidence: configuration.jointConfidence) != nil {
                count += 1
            }
        }
        return person.boundingBox.intersectionOverUnion(with: target.rect) * 3
            + Double(completeJoints) / Double(BodyJoint.allCases.count)
            + person.confidence
    }

    private func evaluatePose(_ person: PersonObservation) -> PoseEvaluation {
        guard let armRule = configuration.armRules[target.poseTemplate] else {
            return PoseEvaluation(status: .unknown, instruction: nil, supported: false)
        }

        let direction = inferredDirection(person)
        let directionSupported = direction != nil && target.bodyDirection != "back"
        if let direction, !directionMatches(direction, target: target.bodyDirection) {
            return PoseEvaluation(status: .adjust, instruction: .adjustBodyDirection, supported: true)
        }

        switch evaluateArmRule(armRule, person: person) {
        case .some(false):
            return PoseEvaluation(status: .adjust, instruction: .adjustArm, supported: true)
        case .none:
            return PoseEvaluation(status: .unknown, instruction: nil, supported: false)
        case .some(true):
            return PoseEvaluation(
                status: directionSupported ? .acceptable : .unknown,
                instruction: nil,
                supported: directionSupported
            )
        }
    }

    private func overlapCorrection(
        person: PersonObservation,
        targetRect: NormalizedRect
    ) -> CurrentAlignment.InstructionCode {
        let horizontalError = person.boundingBox.center.x - targetRect.center.x
        let normalizedHorizontalError = abs(horizontalError) / max(targetRect.width, 0.001)
        let personArea = person.boundingBox.width * person.boundingBox.height
        let targetArea = targetRect.width * targetRect.height
        let normalizedAreaError = abs(personArea - targetArea) / max(targetArea, 0.001)

        if normalizedHorizontalError >= normalizedAreaError, abs(horizontalError) > 0.001 {
            return horizontalError < 0 ? .moveRight : .moveLeft
        }
        return personArea < targetArea ? .moveForward : .moveBackward
    }

    private func applyOverlapCorrectionStatus(
        _ instruction: CurrentAlignment.InstructionCode,
        positionStatus: inout CurrentAlignment.PositionStatus,
        scaleStatus: inout CurrentAlignment.ScaleStatus
    ) {
        switch instruction {
        case .moveLeft:
            positionStatus = .moveLeft
        case .moveRight:
            positionStatus = .moveRight
        case .moveForward:
            scaleStatus = .moveForward
        case .moveBackward:
            scaleStatus = .moveBackward
        default:
            break
        }
    }

    private func inferredDirection(_ person: PersonObservation) -> String? {
        guard let nose = person.joint(.nose, minimumConfidence: configuration.jointConfidence)?.point,
              let neck = person.joint(.neck, minimumConfidence: configuration.jointConfidence)?.point,
              let left = person.joint(.leftShoulder, minimumConfidence: configuration.jointConfidence)?.point,
              let right = person.joint(.rightShoulder, minimumConfidence: configuration.jointConfidence)?.point,
              person.joint(.leftHip, minimumConfidence: configuration.jointConfidence) != nil,
              person.joint(.rightHip, minimumConfidence: configuration.jointConfidence) != nil
        else {
            return nil
        }
        let shoulderWidth = max(abs(right.x - left.x), 0.04)
        let offset = (nose.x - neck.x) / shoulderWidth
        if offset < -0.12 { return "left" }
        if offset > 0.12 { return "right" }
        return "front"
    }

    private func directionMatches(_ observed: String, target: String) -> Bool {
        switch target {
        case "slightly_left": observed == "left" || observed == "front"
        case "slightly_right": observed == "right" || observed == "front"
        default: observed == target
        }
    }

    private func evaluateArmRule(_ rule: CoarseArmRule, person: PersonObservation) -> Bool? {
        switch rule {
        case .none:
            return true
        case .oneWristAboveHip:
            let pairs: [(BodyJoint, BodyJoint)] = [(.leftWrist, .leftHip), (.rightWrist, .rightHip)]
            var observedPair = false
            for (wristName, hipName) in pairs {
                guard let wrist = person.joint(wristName, minimumConfidence: configuration.jointConfidence)?.point,
                      let hip = person.joint(hipName, minimumConfidence: configuration.jointConfidence)?.point
                else { continue }
                observedPair = true
                if wrist.y < hip.y - 0.03 { return true }
            }
            return observedPair ? false : nil
        case .oneArmExtended:
            let pairs: [(BodyJoint, BodyJoint)] = [(.leftWrist, .leftShoulder), (.rightWrist, .rightShoulder)]
            var observedPair = false
            for (wristName, shoulderName) in pairs {
                guard let wrist = person.joint(wristName, minimumConfidence: configuration.jointConfidence)?.point,
                      let shoulder = person.joint(shoulderName, minimumConfidence: configuration.jointConfidence)?.point
                else { continue }
                observedPair = true
                let distance = hypot(wrist.x - shoulder.x, wrist.y - shoulder.y)
                if distance >= person.boundingBox.height * 0.30 { return true }
            }
            return observedPair ? false : nil
        }
    }

    private mutating func stabilize(_ instruction: CurrentAlignment.InstructionCode) -> Bool {
        if candidateInstruction == instruction {
            candidateCount += 1
        } else {
            candidateInstruction = instruction
            candidateCount = 1
        }
        if candidateCount >= configuration.instructionConfirmationSamples {
            confirmedInstruction = instruction
            return true
        }
        return confirmedInstruction == instruction
    }

    private mutating func resetAlignedState() {
        alignedSince = nil
        alignedSamples = 0
    }
}
