# SoloShot AI

SoloShot AI is a contract-first monorepo for an end-to-end solo travel shooting coach. W0 establishes the shared contracts, W1 adds the Agent/Skill API, W2 adds the H5 capture/evaluation path, W3 adds secure H5-to-iPhone ShotPlan handoff with offline recovery, W4 adds on-device camera/Vision alignment, and W5 closes the native capture, selected-frame upload, evaluation, and second-shot loop.

## Prerequisites

- Python 3.12
- Node.js 24 or newer
- Java 21 (for OpenAPI Generator)
- Docker Desktop with Docker Compose
- Xcode 26 and XcodeGen 2.45 or newer on macOS

## Bootstrap

```bash
make bootstrap
make generate
```

The bootstrap command creates `.venv`, installs the API development dependencies, and installs the npm workspaces. The preset Fixture flow does not require model credentials.

## Run locally

```bash
cp .env.example .env
make dev-infra
make migrate
make dev-api
make dev-h5
```

- API health: `http://127.0.0.1:8000/health`
- H5: `http://127.0.0.1:5173`
- MinIO console: `http://127.0.0.1:9001`

## Validate W2–W5

```bash
make generate
make lint
make typecheck
make test
make test-api-integration
make evals
make e2e-h5
make test-ios
make e2e-handoff
make e2e-ios-w4
make e2e-ios-w5
make e2e-w5
```

Generated contract code lives below a `generated/` directory and must not be edited by hand.

## Honest current scope

W2 provides an explicitly labeled preset Fixture path plus Volcengine Ark Live paths for custom media and scene adaptation. W3 adds a ten-minute QR/code handoff, atomic single-device claim, Keychain capability storage, app-owned 24-hour task cache, and offline task summary. W4 adds a portrait rear-1× AVFoundation preview, local Vision body pose, centralized coordinate mapping, a native 2D overlay, controlled Chinese instructions, speech/haptics, and explicit composition-only/manual fallbacks.

W5 adds three-photo capture or a 5–8 second silent 720p clip, deterministic on-device candidate selection, explicit selected-JPEG upload consent, a resumable ordered outbox, result evaluation, one controlled retake instruction, a second round, and cross-device H5 result recovery. Original video, discarded candidates, Vision coordinates, and camera preview frames are never uploaded. Preset results remain clearly marked as Fixture fixed scores; custom and scene-adaptation results require Live Ark and never silently fall back to Fixture.

W3 is not closed until an HTTPS test deployment and its documented real-iPhone handoff run pass. W4 and W5 are likewise only locally/CI/Simulator complete until their real-device camera, Vision, recording, thermal, interruption, offline-resume, and latency checklists pass. Real Ark quality is a separate paid smoke/data acceptance item. The Chinese runbook and current acceptance reports live under `docs/`.
