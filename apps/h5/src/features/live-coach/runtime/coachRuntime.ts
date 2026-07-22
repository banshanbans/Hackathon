import { aspectFillPoint, aspectFillRect } from "../camera/coordinateMapper";
import { AlignmentEngine } from "../domain/alignmentEngine";
import { alignmentConfiguration } from "../domain/alignmentConfig";
import type { AlignmentDecision, CoachTarget } from "../domain/alignmentModels";
import { observationsFromMediaPipe } from "../pose/mediapipeAdapter";
import type { PoseRuntime } from "../pose/poseLandmarker";

export type CoachRuntimeStats = {
  inferenceCount: number;
  inferenceP50: number;
  inferenceP95: number;
  sampleIntervalMs: number;
};

export class CoachRuntime {
  private readonly engine: AlignmentEngine;
  private frameId: number | null = null;
  private running = false;
  private lastInferenceAt = 0;
  private sampleIntervalMs = alignmentConfiguration.nominalSampleIntervalMs;
  private latencies: number[] = [];
  private latestDecision: AlignmentDecision | null = null;

  constructor(
    private readonly video: HTMLVideoElement,
    private readonly canvas: HTMLCanvasElement,
    private readonly pose: PoseRuntime,
    private readonly target: CoachTarget,
    private readonly onDecision: (decision: AlignmentDecision, stats: CoachRuntimeStats) => void,
  ) {
    this.engine = new AlignmentEngine(target);
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    this.loop(performance.now());
  }

  manualCompletion(): AlignmentDecision {
    const decision = this.engine.manualCompletion();
    this.latestDecision = decision;
    this.render(decision);
    this.onDecision(decision, this.stats());
    return decision;
  }

  getDecision(): AlignmentDecision | null {
    return this.latestDecision;
  }

  stop(): void {
    this.running = false;
    if (this.frameId !== null) cancelAnimationFrame(this.frameId);
    this.frameId = null;
    this.pose.close();
    const context = this.canvas.getContext("2d");
    context?.clearRect(0, 0, this.canvas.width, this.canvas.height);
  }

  private loop = (now: number): void => {
    if (!this.running) return;
    this.resizeCanvas();
    if (
      this.video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA &&
      now - this.lastInferenceAt >= this.sampleIntervalMs
    ) {
      this.lastInferenceAt = now;
      const started = performance.now();
      try {
        const result = this.pose.detect(this.video, now);
        const decision = this.engine.process(observationsFromMediaPipe(result, now), now);
        const latency = performance.now() - started;
        this.latencies.push(latency);
        if (this.latencies.length > 60) this.latencies.shift();
        this.adaptInterval();
        this.latestDecision = { ...decision, latencyMilliseconds: latency };
        this.render(this.latestDecision);
        this.onDecision(this.latestDecision, this.stats());
      } catch {
        this.sampleIntervalMs = Math.max(
          this.sampleIntervalMs,
          alignmentConfiguration.degradedSampleIntervalMs,
        );
        const decision = this.engine.process([], now);
        this.latestDecision = decision;
        this.render(decision);
        this.onDecision(decision, this.stats());
      }
    }
    this.frameId = requestAnimationFrame(this.loop);
  };

  private adaptInterval(): void {
    const p95 = this.percentile(0.95);
    if (p95 <= 120) this.sampleIntervalMs = 125;
    else if (p95 <= 220) this.sampleIntervalMs = 200;
    else if (p95 <= 350) this.sampleIntervalMs = 333;
    else this.sampleIntervalMs = 500;
  }

  private stats(): CoachRuntimeStats {
    return {
      inferenceCount: this.latencies.length,
      inferenceP50: this.percentile(0.5),
      inferenceP95: this.percentile(0.95),
      sampleIntervalMs: this.sampleIntervalMs,
    };
  }

  private percentile(value: number): number {
    if (this.latencies.length === 0) return 0;
    const sorted = [...this.latencies].sort((left, right) => left - right);
    return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * value))] ?? 0;
  }

  private resizeCanvas(): void {
    const rect = this.canvas.getBoundingClientRect();
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    const width = Math.max(1, Math.round(rect.width * ratio));
    const height = Math.max(1, Math.round(rect.height * ratio));
    if (this.canvas.width !== width || this.canvas.height !== height) {
      this.canvas.width = width;
      this.canvas.height = height;
    }
  }

  private render(decision: AlignmentDecision): void {
    const context = this.canvas.getContext("2d");
    if (context === null) return;
    const rect = this.canvas.getBoundingClientRect();
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    context.clearRect(0, 0, rect.width, rect.height);
    const args = [
      this.video.videoWidth,
      this.video.videoHeight,
      rect.width,
      rect.height,
    ] as const;
    const target = aspectFillRect(this.target.rect, ...args);
    context.strokeStyle = decision.readyToCapture ? "#38d27a" : "#ff7a2f";
    context.lineWidth = 3;
    context.setLineDash([10, 7]);
    context.strokeRect(target.x, target.y, target.width, target.height);
    context.setLineDash([]);
    const head = aspectFillPoint(
      { x: this.target.rect.x + this.target.rect.width / 2, y: this.target.rect.y },
      ...args,
    );
    context.beginPath();
    context.arc(head.x, head.y + Math.min(28, target.height * 0.08), Math.min(22, target.width * 0.15), 0, Math.PI * 2);
    context.stroke();
    const person = decision.selectedPerson;
    if (person !== null) {
      const box = aspectFillRect(person.boundingBox, ...args);
      context.strokeStyle = "rgba(255,255,255,.82)";
      context.lineWidth = 2;
      context.strokeRect(box.x, box.y, box.width, box.height);
    }
  }
}
