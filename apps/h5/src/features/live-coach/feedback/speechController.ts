import { alignmentConfiguration } from "../domain/alignmentConfig";
import type { InstructionCode } from "../domain/alignmentModels";
import { instructionCopy } from "./instructionCopy";

export class SpeechController {
  private lastInstruction: InstructionCode | null = null;
  private lastSpokenAt = 0;

  constructor(private enabled: boolean) {}

  setEnabled(enabled: boolean): void {
    this.enabled = enabled;
    if (!enabled) window.speechSynthesis?.cancel();
  }

  speak(instruction: InstructionCode, now = performance.now()): void {
    if (
      !this.enabled ||
      !("speechSynthesis" in window) ||
      instruction === this.lastInstruction ||
      now - this.lastSpokenAt < alignmentConfiguration.speechMinimumIntervalMs
    ) {
      return;
    }
    window.speechSynthesis.cancel();
    const utterance = new SpeechSynthesisUtterance(instructionCopy[instruction]);
    utterance.lang = "zh-CN";
    utterance.rate = 1;
    window.speechSynthesis.speak(utterance);
    this.lastInstruction = instruction;
    this.lastSpokenAt = now;
  }

  stop(): void {
    window.speechSynthesis?.cancel();
  }
}
