# AGENTS.md

This file governs the entire repository unless a more specific `AGENTS.md` exists in a subdirectory.

## Mission

Build SoloShot AI as a reliable end-to-end AI product, not as disconnected demos. The repository must preserve one working path from reference selection to shot plan, capture evaluation, second-shot improvement, and shareable output.

The project intentionally uses Codex as the primary implementation partner. Generate, refactor, test, and document code autonomously, but do not trade correctness, transparency, or demo stability for code volume.

## Read before changing code

1. `PRODUCT_OWNER_GUIDE.md` — product scope, competition strategy, priorities, and acceptance.
2. `CODEX_IMPLEMENTATION_SPEC.md` — architecture, contracts, work packages, and technical Definition of Done.
3. `packages/contracts/openapi.yaml` and schemas — source of truth for cross-client data.
4. Relevant ADRs and the nearest subdirectory `AGENTS.md`, if present.

The original V3.0 document under `reference/` is supporting context, not the first implementation source.

## Priority order

When trade-offs are necessary, use this order:

1. End-to-end correctness and honest behavior.
2. On-device iOS demo stability.
3. H5 public accessibility and recovery.
4. Contract compatibility across H5, iOS, and API.
5. Observability, tests, and failure handling.
6. UI polish and optional features.

Do not add a P1/P2 feature while a P0 path is broken.

## Product boundaries

- One shared Agent/Skill core; two differentiated clients.
- H5 owns low-friction access, reference selection, upload/evaluation, handoff, sharing, and growth.
- iOS owns AVFoundation, Vision, real-time alignment, native overlay, speech/haptics, and capture.
- The iOS real-time loop must not call an LLM or depend on network availability.
- H5 does not need parity with native real-time pose tracking.
- First release uses a native 2D screen-space overlay, not complex world-anchored 3D AR.
- Never claim that a Douyin publish/account/POI integration is live unless it has been implemented and verified. Use an adapter and label previews honestly.

## Repository boundaries

Preferred dependency direction:

```text
UI / Framework adapters
        ↓
Application services / use cases
        ↓
Domain models and rules
        ↑
Ports implemented by providers, persistence, media, and networking
```

Rules:

- Domain code must not import FastAPI, database clients, model SDKs, AVFoundation, Vision, or React.
- Clients must not call model providers directly.
- Long prompts live under `packages/prompts/`, not inline in route handlers.
- Generated clients/types live in `generated/` and must not be hand-edited.
- Shared business enums and schemas originate in `packages/contracts/`.
- Do not duplicate instruction priority, issue-code mappings, or schema definitions across layers without a generated/shared source.

## Work method

- Inspect the current repository before editing.
- Implement the smallest complete vertical slice for the assigned work package.
- Prefer extending existing patterns over introducing new frameworks.
- Avoid broad rewrites unless the current architecture blocks an accepted P0 path.
- Keep main/demo branches runnable; do not leave half-migrated contracts.
- Use feature flags for incomplete or risky features.
- Mock AI/media only behind explicit flags such as `MOCK_AI_ENABLED`; mark mock behavior in logs and developer UI.
- Never present fixture output as a live result.
- When adding a new Skill, add schema, version, tests/evals, trace fields, timeout, and fallback in the same change.
- When changing OpenAPI or JSON Schema, regenerate H5/iOS clients and run contract tests in the same change.

## Coding standards

### General

- Write clear, maintainable code; avoid clever abstractions before the second real use case.
- Validate external input at boundaries.
- Use typed domain models and explicit enums instead of magic strings.
- Include cancellation and timeout behavior for network, model, and media jobs.
- Return recoverable errors with stable codes.
- Do not log secrets, signed URLs, raw access tokens, or user media bytes.
- Preserve source attribution concepts and user deletion paths.

### Python / API

- Python 3.12, typed functions, Pydantic v2.
- Use async only for actual async I/O; do not wrap CPU-bound FFmpeg/OpenCV work in the event loop.
- Routes should orchestrate application services, not contain provider prompts or business rules.
- Provider SDKs must be behind adapters.
- Run `ruff`, type checking, and pytest for touched code.

### TypeScript / H5

- Keep `strict` TypeScript enabled.
- Avoid `any`; narrow unknown external data through generated schemas/types.
- Separate server state from local UI state.
- Coordinate conversion logic must be pure and tested.
- File upload is the reliable fallback even when camera capture is supported.
- Accessibility: large tap targets, visible status, and non-audio alternatives for instructions.

### Swift / iOS

- Swift Concurrency with explicit actor/thread boundaries.
- Camera session work runs off the main thread; UI changes return to the main actor.
- Vision/framework types are converted into domain structs before reaching views.
- Coordinate mapping is centralized and unit-tested.
- Alignment thresholds come from configuration, not scattered literals.
- Speech text comes from a controlled local mapping, never raw model output.
- Every capture file has an owner and cleanup lifecycle.

## Contracts and versions

- Every public DTO includes `schema_version` or uses an explicitly versioned endpoint.
- All normalized coordinates are in `[0, 1]` and document their origin convention.
- Handoff codes are short-lived, revocable, and safe to expose; they do not contain session data.
- Writes use idempotency where retries can duplicate work.
- Agent and Skill traces record versions, latency, cost, confidence, fallback, and errors.

## Tests required by change type

| Change | Required validation |
|---|---|
| Domain rule / enum | Unit tests for normal and boundary cases |
| OpenAPI / schema | Contract tests + regenerated clients |
| Skill / prompt | Unit tests + representative eval cases |
| H5 flow | Component/unit tests; Playwright for critical path |
| iOS alignment/camera | Unit tests for rules/coordinates; simulator build; device note where required |
| Media render | Golden/fixture output and timeout/error test |
| Handoff/session | Integration tests for expiry, duplicate claim, idempotency, and recovery |
| Analytics | Event schema, deduplication, and privacy test |

Do not disable a failing test simply to make CI green. Fix it, replace it with a correct test, or document a temporary quarantine with an owner and expiration.

## Definition of Done

A task is done only when:

- The user-visible or API behavior matches its acceptance criteria.
- The P0 path remains runnable.
- Tests, lint, type checks, and relevant builds pass.
- Error, timeout, cancellation, and fallback paths are implemented.
- Logs/metrics are useful and contain no sensitive data.
- Contract changes are propagated to all clients.
- Documentation and `.env.example` are updated.
- Feature flags and mock status are explicit.
- The final report lists files changed, commands run, assumptions, risks, and the next recommended task.

## Safety, privacy, and honest demo behavior

- Do not implement face identity recognition or attractiveness/body scoring.
- Block or warn about dangerous locations and instructions.
- Do not recommend roads, tracks, cliff edges, restricted areas, or unstable support.
- User upload and publish actions require clear consent.
- Support deletion of sessions and temporary media.
- Do not strip watermarks or build content-copying behavior.
- Do not label cached, fixture, or prerecorded results as live.

## Suggested command surface

Prefer repository commands when available:

```bash
make bootstrap
make dev-infra
make dev-api
make dev-h5
make generate
make lint
make typecheck
make test
make test-contracts
make evals
make e2e-h5
make seed-demo
```

For iOS, use the documented scheme and destination. Simulator success does not replace required device validation for camera/Vision behavior.

## Work-package discipline

Work in order unless the user explicitly changes priorities:

```text
W0 contracts/repo
W1 Agent API
W2 H5 end-to-end
W3 handoff
W4 iOS camera/Vision/overlay
W5 capture/evaluation/retake
W6 content/growth/trace
W7 hardening/freeze
```

At the end of each work package, provide:

```text
Summary
Files changed
Validation commands and results
User-visible behavior
Known risks or device-only gaps
Next smallest recommended work package
```

## When to ask the user

Ask only when a decision would materially change product scope, external services, data retention/privacy, paid model usage, Apple entitlements/distribution, or the accepted API contract.

For local implementation details, choose the simplest typed, testable, reversible approach and proceed.
