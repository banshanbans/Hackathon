# SoloShot AI

SoloShot AI is a contract-first monorepo for an end-to-end solo travel shooting coach. W0 establishes the shared contracts, W1 adds the Agent/Skill API, W2 adds the H5 capture/evaluation path, and W3 adds secure H5-to-iPhone ShotPlan handoff with offline recovery.

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

## Validate W2/W3

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
```

Generated contract code lives below a `generated/` directory and must not be edited by hand.

## Honest current scope

W2 provides an explicitly labeled preset Fixture path plus Volcengine Ark Live paths for custom media and scene adaptation. W3 adds a ten-minute QR/code handoff, atomic single-device claim, Keychain capability storage, app-owned 24-hour task cache, and offline task summary. Native camera/Vision alignment remains W4 work. W3 is not closed until an HTTPS test deployment and the documented real-iPhone run both pass; local/CI results alone are labeled accordingly.

The Chinese runbook and current acceptance status live in `docs/runbooks/local-development.md`, `docs/W2_H5_STATUS.md`, and `docs/W3_HANDOFF_STATUS.md`.
