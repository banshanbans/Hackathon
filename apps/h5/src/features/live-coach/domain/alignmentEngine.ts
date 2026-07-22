import { alignmentConfiguration, type AlignmentConfiguration, type CoarseArmRule } from "./alignmentConfig";
import {
  bodyJoints,
  center,
  intersectionOverUnion,
  joint,
  type AlignmentDecision,
  type CoachTarget,
  type InstructionCode,
  type PersonObservation,
} from "./alignmentModels";

type PoseEvaluation = {
  status: AlignmentDecision["poseStatus"];
  instruction: InstructionCode | null;
  supported: boolean;
};

export class AlignmentEngine {
  private candidateInstruction: InstructionCode | null = null;
  private candidateCount = 0;
  private confirmedInstruction: InstructionCode | null = null;
  private positionWasCentered = false;
  private scaleWasCorrect = false;
  private alignedSince: number | null = null;
  private alignedSamples = 0;
  private noUsablePersonSince: number | null;

  constructor(
    private readonly target: CoachTarget,
    private readonly configuration: AlignmentConfiguration = alignmentConfiguration,
    startedAt = performance.now(),
  ) {
    this.noUsablePersonSince = startedAt;
  }

  process(observations: PersonObservation[], now = performance.now()): AlignmentDecision {
    const latencyStart = performance.now();
    const credible = observations.filter(
      (person) => person.confidence >= this.configuration.crediblePersonConfidence,
    );
    const selected = this.selectPerson(credible);
    if (selected === null) {
      this.noUsablePersonSince ??= now;
    } else {
      this.noUsablePersonSince = null;
    }

    let personDetected = credible.length > 0;
    let multiplePeople = credible.length > 1;
    let fullBodyVisible = false;
    let positionStatus: AlignmentDecision["positionStatus"] = "unknown";
    let scaleStatus: AlignmentDecision["scaleStatus"] = "unknown";
    let poseStatus: AlignmentDecision["poseStatus"] = "unknown";
    let rawInstruction: InstructionCode = "no_person";
    let rawCompletionMode: AlignmentDecision["completionMode"] = null;
    let poseSupported = false;
    let stabilityScore = 0;
    let overlapRatio = 0;
    let countdownStillValid = false;

    if (multiplePeople) {
      rawInstruction = "multiple_people";
      this.resetAlignedState();
    } else if (selected !== null) {
      personDetected = true;
      multiplePeople = false;
      const headVisible =
        joint(selected, "nose", this.configuration.jointConfidence) !== null ||
        joint(selected, "neck", this.configuration.jointConfidence) !== null;
      const feetVisible =
        joint(selected, "leftAnkle", this.configuration.jointConfidence) !== null &&
        joint(selected, "rightAnkle", this.configuration.jointConfidence) !== null;
      fullBodyVisible = headVisible && feetVisible;

      if (!headVisible) {
        rawInstruction = "head_outside";
        this.resetAlignedState();
      } else if (!feetVisible) {
        rawInstruction = "feet_outside";
        this.resetAlignedState();
      } else {
        const targetRect = this.target.rect;
        overlapRatio = intersectionOverUnion(selected.boundingBox, targetRect);
        const heightError =
          Math.abs(selected.boundingBox.height - targetRect.height) / Math.max(targetRect.height, 0.001);
        const heightTolerance = this.scaleWasCorrect
          ? this.configuration.heightExitTolerance
          : this.configuration.heightEnterTolerance;
        if (heightError <= heightTolerance) {
          this.scaleWasCorrect = true;
          scaleStatus = "correct";
        } else {
          this.scaleWasCorrect = false;
          scaleStatus = selected.boundingBox.height < targetRect.height ? "move_forward" : "move_backward";
          rawInstruction = scaleStatus;
          this.resetAlignedState();
        }

        if (this.scaleWasCorrect) {
          const horizontalError = center(selected.boundingBox).x - center(targetRect).x;
          const tolerance = this.positionWasCentered
            ? this.configuration.horizontalExitTolerance
            : this.configuration.horizontalEnterTolerance;
          if (Math.abs(horizontalError) <= tolerance) {
            this.positionWasCentered = true;
            positionStatus = "centered";
          } else {
            this.positionWasCentered = false;
            positionStatus = horizontalError < 0 ? "move_right" : "move_left";
            rawInstruction = positionStatus;
            this.resetAlignedState();
          }
        }

        if (this.scaleWasCorrect && this.positionWasCentered) {
          const pose = this.evaluatePose(selected);
          poseStatus = pose.status;
          poseSupported = pose.supported;
          if (pose.instruction !== null) {
            rawInstruction = pose.instruction;
            this.resetAlignedState();
          } else {
            countdownStillValid =
              overlapRatio + 1e-9 >= this.configuration.overlapExitThreshold;
            if (overlapRatio + 1e-9 >= this.configuration.overlapEnterThreshold) {
              if (this.alignedSince === null) {
                this.alignedSince = now;
                this.alignedSamples = 1;
              } else {
                this.alignedSamples += 1;
              }
              const duration = now - this.alignedSince;
              const ready =
                this.alignedSamples >= this.configuration.readyMinimumSamples &&
                duration >= this.configuration.readyMinimumDurationMs;
              rawInstruction = ready ? "ready_to_capture" : "hold_still";
              rawCompletionMode = ready ? (pose.supported ? "verified" : "composition_only") : null;
            } else {
              rawInstruction = this.overlapCorrection(selected);
              if (rawInstruction === "move_left" || rawInstruction === "move_right") {
                positionStatus = rawInstruction;
              } else if (rawInstruction === "move_forward" || rawInstruction === "move_backward") {
                scaleStatus = rawInstruction;
              }
              this.resetAlignedState();
            }
          }
        }

        const horizontalScore =
          1 -
          Math.min(
            1,
            Math.abs(center(selected.boundingBox).x - center(targetRect).x) /
              Math.max(this.configuration.horizontalExitTolerance, 0.001),
          );
        const heightScore =
          1 - Math.min(1, heightError / Math.max(this.configuration.heightExitTolerance, 0.001));
        stabilityScore = Math.max(0, Math.min(1, (horizontalScore + heightScore) / 2));
      }
    } else {
      this.resetAlignedState();
    }

    const instructionConfirmed = this.stabilize(rawInstruction);
    const displayedInstruction = this.confirmedInstruction ?? rawInstruction;
    const completionMode =
      displayedInstruction === "ready_to_capture" && instructionConfirmed ? rawCompletionMode : null;
    return {
      personDetected,
      multiplePeople,
      fullBodyVisible,
      positionStatus,
      scaleStatus,
      poseStatus,
      instructionCode: displayedInstruction,
      readyToCapture: completionMode !== null,
      stabilityScore,
      selectedPerson: selected,
      overlapRatio,
      countdownStillValid,
      stableDuration: this.alignedSince === null ? 0 : now - this.alignedSince,
      completionMode,
      manualReadyAvailable:
        selected === null && now - (this.noUsablePersonSince ?? now) >= this.configuration.manualFallbackDelayMs,
      poseCheckSupported: poseSupported,
      instructionConfirmed,
      latencyMilliseconds: performance.now() - latencyStart,
    };
  }

  manualCompletion(): AlignmentDecision {
    this.confirmedInstruction = "ready_to_capture";
    this.candidateInstruction = "ready_to_capture";
    this.candidateCount = this.configuration.instructionConfirmationSamples;
    return {
      personDetected: false,
      multiplePeople: false,
      fullBodyVisible: false,
      positionStatus: "unknown",
      scaleStatus: "unknown",
      poseStatus: "unknown",
      instructionCode: "ready_to_capture",
      readyToCapture: true,
      stabilityScore: 0,
      selectedPerson: null,
      overlapRatio: 0,
      countdownStillValid: true,
      stableDuration: 0,
      completionMode: "manual",
      manualReadyAvailable: true,
      poseCheckSupported: false,
      instructionConfirmed: true,
      latencyMilliseconds: 0,
    };
  }

  private selectPerson(observations: PersonObservation[]): PersonObservation | null {
    return (
      observations.reduce<PersonObservation | null>((best, person) => {
        if (best === null) return person;
        const difference = this.selectionScore(person) - this.selectionScore(best);
        return difference > 0 || (difference === 0 && person.confidence > best.confidence) ? person : best;
      }, null)
    );
  }

  private selectionScore(person: PersonObservation): number {
    const complete = bodyJoints.filter(
      (name) => joint(person, name, this.configuration.jointConfidence) !== null,
    ).length;
    return (
      intersectionOverUnion(person.boundingBox, this.target.rect) * 3 +
      complete / bodyJoints.length +
      person.confidence
    );
  }

  private evaluatePose(person: PersonObservation): PoseEvaluation {
    const armRule = this.configuration.armRules[this.target.poseTemplate];
    if (armRule === undefined) return { status: "unknown", instruction: null, supported: false };
    const direction = this.inferredDirection(person);
    const directionSupported = direction !== null && this.target.bodyDirection !== "back";
    if (direction !== null && !this.directionMatches(direction, this.target.bodyDirection)) {
      return { status: "adjust", instruction: "adjust_body_direction", supported: true };
    }
    const arm = this.evaluateArmRule(armRule, person);
    if (arm === false) return { status: "adjust", instruction: "adjust_arm", supported: true };
    if (arm === null) return { status: "unknown", instruction: null, supported: false };
    return {
      status: directionSupported ? "acceptable" : "unknown",
      instruction: null,
      supported: directionSupported,
    };
  }

  private overlapCorrection(person: PersonObservation): InstructionCode {
    const target = this.target.rect;
    const horizontal = center(person.boundingBox).x - center(target).x;
    const normalizedHorizontal = Math.abs(horizontal) / Math.max(target.width, 0.001);
    const personArea = person.boundingBox.width * person.boundingBox.height;
    const targetArea = target.width * target.height;
    const normalizedArea = Math.abs(personArea - targetArea) / Math.max(targetArea, 0.001);
    if (normalizedHorizontal >= normalizedArea && Math.abs(horizontal) > 0.001) {
      return horizontal < 0 ? "move_right" : "move_left";
    }
    return personArea < targetArea ? "move_forward" : "move_backward";
  }

  private inferredDirection(person: PersonObservation): string | null {
    const nose = joint(person, "nose", this.configuration.jointConfidence)?.point;
    const neck = joint(person, "neck", this.configuration.jointConfidence)?.point;
    const left = joint(person, "leftShoulder", this.configuration.jointConfidence)?.point;
    const right = joint(person, "rightShoulder", this.configuration.jointConfidence)?.point;
    if (
      nose === undefined ||
      neck === undefined ||
      left === undefined ||
      right === undefined ||
      joint(person, "leftHip", this.configuration.jointConfidence) === null ||
      joint(person, "rightHip", this.configuration.jointConfidence) === null
    ) {
      return null;
    }
    const width = Math.max(Math.abs(right.x - left.x), 0.04);
    const offset = (nose.x - neck.x) / width;
    if (offset < -0.12) return "left";
    if (offset > 0.12) return "right";
    return "front";
  }

  private directionMatches(observed: string, target: string): boolean {
    if (target === "slightly_left") return observed === "left" || observed === "front";
    if (target === "slightly_right") return observed === "right" || observed === "front";
    return observed === target;
  }

  private evaluateArmRule(rule: CoarseArmRule, person: PersonObservation): boolean | null {
    if (rule === "none") return true;
    if (rule === "one_wrist_above_hip") {
      const pairs = [
        ["leftWrist", "leftHip"],
        ["rightWrist", "rightHip"],
      ] as const;
      let observed = false;
      for (const [wristName, hipName] of pairs) {
        const wrist = joint(person, wristName, this.configuration.jointConfidence)?.point;
        const hip = joint(person, hipName, this.configuration.jointConfidence)?.point;
        if (wrist === undefined || hip === undefined) continue;
        observed = true;
        if (wrist.y < hip.y - 0.03) return true;
      }
      return observed ? false : null;
    }
    const pairs = [
      ["leftWrist", "leftShoulder"],
      ["rightWrist", "rightShoulder"],
    ] as const;
    let observed = false;
    for (const [wristName, shoulderName] of pairs) {
      const wrist = joint(person, wristName, this.configuration.jointConfidence)?.point;
      const shoulder = joint(person, shoulderName, this.configuration.jointConfidence)?.point;
      if (wrist === undefined || shoulder === undefined) continue;
      observed = true;
      if (Math.hypot(wrist.x - shoulder.x, wrist.y - shoulder.y) >= person.boundingBox.height * 0.3) {
        return true;
      }
    }
    return observed ? false : null;
  }

  private stabilize(instruction: InstructionCode): boolean {
    if (this.candidateInstruction === instruction) this.candidateCount += 1;
    else {
      this.candidateInstruction = instruction;
      this.candidateCount = 1;
    }
    if (this.candidateCount >= this.configuration.instructionConfirmationSamples) {
      this.confirmedInstruction = instruction;
      return true;
    }
    return this.confirmedInstruction === instruction;
  }

  private resetAlignedState(): void {
    this.alignedSince = null;
    this.alignedSamples = 0;
  }
}
