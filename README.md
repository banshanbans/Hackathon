# SoloShot AI

SoloShot AI is a contract-first monorepo for an end-to-end solo travel shooting coach. W0 establishes the shared contracts, local infrastructure, and buildable API, H5, and iOS skeletons. Agent and Skill behavior starts in W1.

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

The bootstrap command creates `.venv`, installs the API development dependencies, and installs the npm workspaces. No model credentials are required for W0.

## Run locally

```bash
cp .env.example .env
make dev-infra
make dev-api
make dev-h5
```

- API health: `http://127.0.0.1:8000/health`
- H5: `http://127.0.0.1:5173`
- MinIO console: `http://127.0.0.1:9001`

## Validate W0

```bash
make generate
make lint
make typecheck
make test
make test-ios
```

Generated contract code lives below a `generated/` directory and must not be edited by hand.

## Honest W0 scope

Only `/health` is implemented by the API in W0. The `/api/v1` operations are defined contract-first for later work packages; they are not exposed as working endpoints yet. The H5 and iOS apps visibly identify themselves as W0 foundations and do not present fixture or mock output as live AI.
