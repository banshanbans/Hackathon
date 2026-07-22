import {
  aspectFillGeometry,
  mediaObservationToViewport,
  viewportPoint,
  viewportRect,
} from "../camera/coordinateMapper";
import { AlignmentEngine } from "../domain/alignmentEngine";
import { alignmentConfiguration } from "../domain/alignmentConfig";
import type { AlignmentDecision, CoachTarget } from "../domain/alignmentModels";
import {
  projectMediaMaskToViewport,
  rasterizeContour,
  silhouetteDice,
  transformContour,
  type BinarySilhouetteMask,
  type SilhouetteContour,
} from "../domain/silhouette";
import { observationsFromMediaPipe } from "../pose/mediapipeAdapter";
import type { PoseRuntime } from "../pose/poseLandmarker";

export type CoachRuntimeStats = {
  inferenceCount: number;
  inferenceP50: number;
  inferenceP95: number;
  sampleIntervalMs: number;
  maskIntervalMs: number;
};

export class CoachRuntime {
  private readonly engine: AlignmentEngine;
  private frameId: number | null = null;
  private running = false;
  private lastInferenceAt = 0;
  private sampleIntervalMs = alignmentConfiguration.nominalSampleIntervalMs;
  private latencies: number[] = [];
  private latestDecision: AlignmentDecision | null = null;
  private latestMasks: Array<BinarySilhouetteMask | null> = [];
  private lastMaskAt = Number.NEGATIVE_INFINITY;
  private latestSilhouetteScore: number | null = null;
  private firstLiveMaskAt: number | null = null;
  private readonly targetMatchMask: BinarySilhouetteMask | null;
  private readonly maskCanvas = document.createElement("canvas");

  constructor(
    private readonly video: HTMLVideoElement,
    private readonly canvas: HTMLCanvasElement,
    private readonly pose: PoseRuntime,
    private readonly target: CoachTarget,
    private readonly referenceContour: SilhouetteContour | null,
    private readonly onDecision: (decision: AlignmentDecision, stats: CoachRuntimeStats) => void,
  ) {
    this.engine = new AlignmentEngine(target);
    this.targetMatchMask = referenceContour === null
      ? null
      : rasterizeContour(transformContour(referenceContour, target.rect));
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
        const includeMasks = now - this.lastMaskAt >= this.maskInterval();
        const result = this.pose.detect(this.video, now, includeMasks);
        const canvasRect = this.canvas.getBoundingClientRect();
        const observations = observationsFromMediaPipe(result, now).flatMap((observation) => {
          const mapped = mediaObservationToViewport(
            observation,
            this.video.videoWidth,
            this.video.videoHeight,
            canvasRect.width,
            canvasRect.height,
          );
          return mapped === null ? [] : [mapped];
        });
        const decision = this.engine.process(observations, now);
        if (includeMasks) {
          this.latestMasks = result.masks;
          this.lastMaskAt = now;
          const hasForeground = result.masks.some(
            (mask) => mask !== null && mask.data.some((value) => value > 0),
          );
          if (decision.personDetected && hasForeground) this.firstLiveMaskAt ??= now;
          this.latestSilhouetteScore = this.matchSilhouette(decision, canvasRect);
        } else if (!decision.personDetected || decision.multiplePeople) {
          this.latestSilhouetteScore = null;
        }
        const latency = performance.now() - started;
        this.latencies.push(latency);
        if (this.latencies.length > 60) this.latencies.shift();
        this.adaptInterval();
        this.latestDecision = {
          ...decision,
          silhouetteScore: this.latestSilhouetteScore,
          latencyMilliseconds: latency,
        };
        this.render(this.latestDecision);
        this.onDecision(this.latestDecision, this.stats());
      } catch {
        this.sampleIntervalMs = Math.max(
          this.sampleIntervalMs,
          alignmentConfiguration.degradedSampleIntervalMs,
        );
        const decision = this.engine.process([], now);
        this.latestMasks = [];
        this.latestSilhouetteScore = null;
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
      maskIntervalMs: this.maskInterval(),
    };
  }

  private percentile(value: number): number {
    if (this.latencies.length === 0) return 0;
    const sorted = [...this.latencies].sort((left, right) => left - right);
    return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * value))] ?? 0;
  }

  private maskInterval(): number {
    return this.percentile(0.95) > 350 ? 750 : 250;
  }

  private matchSilhouette(
    decision: AlignmentDecision,
    view: DOMRect,
  ): number | null {
    if (
      this.targetMatchMask === null ||
      decision.multiplePeople ||
      decision.selectedPerson === null
    ) {
      return null;
    }
    // Selfie Segmenter returns one foreground mask containing all people.
    // Multi-person frames are filtered above and use warning feedback only.
    const mask = this.latestMasks[0] ?? null;
    if (mask === null) return null;
    const projected = projectMediaMaskToViewport(
      mask,
      this.video.videoWidth,
      this.video.videoHeight,
      view.width,
      view.height,
      this.targetMatchMask.width,
      this.targetMatchMask.height,
    );
    return silhouetteDice(this.targetMatchMask, projected);
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
    this.drawLiveMasks(context, rect, decision);
    this.drawTarget(context, rect, decision);
  }

  private drawTarget(
    context: CanvasRenderingContext2D,
    rect: DOMRect,
    decision: AlignmentDecision,
  ): void {
    const target = viewportRect(this.target.rect, rect.width, rect.height);
    const recommendedMatch = (decision.silhouetteScore ?? 0) >= 0.8;
    context.strokeStyle = recommendedMatch ? "#38d27a" : "#ff7a2f";
    context.lineWidth = 3;
    context.setLineDash([10, 7]);
    if (this.referenceContour !== null) {
      for (const loop of this.referenceContour.loops) {
        const first = loop[0];
        if (first === undefined) continue;
        context.beginPath();
        context.moveTo(target.x + first.x * target.width, target.y + first.y * target.height);
        for (const point of loop.slice(1)) {
          context.lineTo(target.x + point.x * target.width, target.y + point.y * target.height);
        }
        context.closePath();
        context.stroke();
      }
      context.setLineDash([]);
      return;
    }
    context.strokeRect(target.x, target.y, target.width, target.height);
    context.setLineDash([]);
    const head = viewportPoint(
      { x: this.target.rect.x + this.target.rect.width / 2, y: this.target.rect.y },
      rect.width,
      rect.height,
    );
    context.beginPath();
    context.arc(head.x, head.y + Math.min(28, target.height * 0.08), Math.min(22, target.width * 0.15), 0, Math.PI * 2);
    context.stroke();
  }

  private drawLiveMasks(
    context: CanvasRenderingContext2D,
    rect: DOMRect,
    decision: AlignmentDecision,
  ): void {
    if (!decision.personDetected || this.latestMasks.length === 0) return;
    const recommendedMatch = (decision.silhouetteScore ?? 0) >= 0.8;
    const color = decision.multiplePeople
      ? ([255, 122, 47] as const)
      : recommendedMatch
        ? ([56, 210, 122] as const)
        : ([255, 255, 255] as const);
    const masks = [this.latestMasks[0] ?? null];
    const geometry = aspectFillGeometry(
      this.video.videoWidth,
      this.video.videoHeight,
      rect.width,
      rect.height,
    );
    const fade = this.firstLiveMaskAt === null
      ? 1
      : Math.min(1, (performance.now() - this.firstLiveMaskAt) / 180);
    for (const mask of masks) {
      if (mask === null) continue;
      this.maskCanvas.width = mask.width;
      this.maskCanvas.height = mask.height;
      const maskContext = this.maskCanvas.getContext("2d");
      if (maskContext === null) continue;
      const pixels = maskContext.createImageData(mask.width, mask.height);
      for (let index = 0; index < mask.data.length; index += 1) {
        if ((mask.data[index] ?? 0) === 0) continue;
        const x = index % mask.width;
        const y = Math.floor(index / mask.width);
        const edge =
          x === 0 ||
          y === 0 ||
          x === mask.width - 1 ||
          y === mask.height - 1 ||
          (mask.data[index - 1] ?? 0) === 0 ||
          (mask.data[index + 1] ?? 0) === 0 ||
          (mask.data[index - mask.width] ?? 0) === 0 ||
          (mask.data[index + mask.width] ?? 0) === 0;
        const offset = index * 4;
        pixels.data[offset] = color[0];
        pixels.data[offset + 1] = color[1];
        pixels.data[offset + 2] = color[2];
        pixels.data[offset + 3] = Math.round((edge ? 220 : 54) * fade);
      }
      maskContext.putImageData(pixels, 0, 0);
      context.drawImage(
        this.maskCanvas,
        geometry.x,
        geometry.y,
        geometry.width,
        geometry.height,
      );
    }
  }
}
