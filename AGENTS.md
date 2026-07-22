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

## UI source hierarchy and Stitch boundary

Before starting W2 or any later H5/iOS UI work, read `docs/STITCH_UI_AUDIT.md`.

When UI sources conflict, use this priority order:

1. `PRODUCT_OWNER_GUIDE.md`.
2. `CODEX_IMPLEMENTATION_SPEC.md`.
3. `packages/contracts/`.
4. Confirmed UI overview images and design tokens.
5. `stitch_ui_visual_replication/` as visual and information-architecture inspiration only.

`stitch_ui_visual_replication/` is not a product source of truth, production implementation, or pixel-perfect acceptance target. Do not copy its disconnected static pages, fake interactions, uncontrolled remote assets, CDN runtime dependencies, inaccessible markup, or unverified security/platform claims into a client.

Production UI must be implemented inside the existing client architecture with real navigation, typed state and contracts, recoverable failures, refresh recovery where required, controlled local assets, responsive behavior, and accessibility. Do not change an accepted P0 flow or add unsupported behavior merely to match Stitch.

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

### Documentation

- All human-authored files under `docs/` must be written in Simplified Chinese.
- Keep code snippets, commands, file paths, identifiers, API field names, and established technical terms in their original form when translating them would reduce accuracy; explain their meaning in Chinese where needed.

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

## Production update and deployment workflow

The canonical single-server deployment target is `ubuntu@1.14.75.189:/opt/soloshot`. The H5 and API public endpoints are `https://shot.socialdog.cn` and `https://shotapi.socialdog.cn`. Use the repository-root `Hackathon.pem` only as the local SSH identity. Keep it mode `600`; never commit it, copy it into the release, print it, or place it in a container image.

The production secret file is `/opt/soloshot/infra/deployment/.env.production`. It is server-owned state: never overwrite it from a local `.env` or `.env.production.example`. Database and object-storage Docker volumes are also server-owned state and must not be deleted during an application update.

### 1. Prepare one deployable local revision

- Review `git status --short` and include only the intended product changes.
- Regenerate clients when contracts changed, and run the validations required by the change-type table above.
- At minimum run `make lint`, `make typecheck`, and the relevant tests. Run `make e2e-h5` for a changed critical H5 path and the documented simulator tests for changed iOS code.
- Commit the intended revision before deployment and record `git rev-parse --short HEAD`. Do not deploy an ambiguous dirty worktree. A user may explicitly authorize a dirty emergency deployment, but its diff and recovery point must be recorded first.
- Confirm the SSH key locally:

```bash
chmod 600 ./Hackathon.pem
ssh -i ./Hackathon.pem ubuntu@1.14.75.189
```

### 2. Back up the current server revision before synchronization

On the server, create a timestamped source snapshot and PostgreSQL dump. Preserve the printed `DEPLOY_STAMP`; it identifies the rollback point.

```bash
cd /opt/soloshot
DEPLOY_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
echo "$DEPLOY_STAMP"
sudo install -d -o ubuntu -g ubuntu "/opt/soloshot-backups/$DEPLOY_STAMP/source"
rsync -a --delete \
  --exclude '.git/' \
  --exclude 'Hackathon.pem' \
  --exclude '*.pem' \
  --exclude 'infra/deployment/.env.production' \
  /opt/soloshot/ "/opt/soloshot-backups/$DEPLOY_STAMP/source/"
sudo docker compose \
  -f infra/deployment/docker-compose.production.yml \
  --env-file infra/deployment/.env.production \
  exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
  > "/opt/soloshot-backups/$DEPLOY_STAMP/postgres.dump"
test -s "/opt/soloshot-backups/$DEPLOY_STAMP/postgres.dump"
```

Stop if the current stack is unhealthy or the dump is empty. Do not make a schema-changing deployment without a valid database backup.

### 3. Preview and synchronize the local revision

Run the preview locally from the repository root. Inspect every deletion, especially under `infra/deployment/`, before running the real synchronization.

```bash
rsync --dry-run --archive --compress --delete --itemize-changes \
  --exclude '.git/' \
  --exclude 'Hackathon.pem' \
  --exclude '*.pem' \
  --exclude '.env' \
  --exclude 'infra/deployment/.env.production' \
  --exclude '.venv/' \
  --exclude 'node_modules/' \
  --exclude 'DerivedData/' \
  --exclude 'dist/' \
  --exclude 'test-results/' \
  --exclude 'playwright-report/' \
  -e 'ssh -i ./Hackathon.pem' \
  ./ ubuntu@1.14.75.189:/opt/soloshot/
```

If the preview is correct, repeat the same command without `--dry-run`. Never add `--delete-excluded`; excluded production secrets and server state must survive the update.

### 4. Rebuild and restart on the server

Run from `/opt/soloshot`. `docker compose config -q` validates the resolved production configuration without printing secrets. The Compose graph runs the one-shot Alembic `migrate` service successfully before starting the API.

```bash
cd /opt/soloshot
test -s infra/deployment/.env.production
sudo docker compose \
  -f infra/deployment/docker-compose.production.yml \
  --env-file infra/deployment/.env.production \
  config -q
sudo docker compose \
  -f infra/deployment/docker-compose.production.yml \
  --env-file infra/deployment/.env.production \
  build api h5
sudo docker compose \
  -f infra/deployment/docker-compose.production.yml \
  --env-file infra/deployment/.env.production \
  up -d --remove-orphans
sudo docker compose \
  -f infra/deployment/docker-compose.production.yml \
  --env-file infra/deployment/.env.production \
  ps -a
```

The deployment is failed if `migrate` did not exit with code `0`, a long-running service is restarting/unhealthy, or Caddy/API logs contain startup errors. Inspect bounded logs rather than streaming indefinitely:

```bash
sudo docker compose \
  -f infra/deployment/docker-compose.production.yml \
  --env-file infra/deployment/.env.production \
  logs --tail=200 migrate api h5 caddy
```

### 5. Verify from outside the server

Run these checks locally so DNS, TLS, Caddy, and the public route are all exercised:

```bash
curl --fail --show-error --silent https://shotapi.socialdog.cn/health
curl --fail --show-error --silent --output /dev/null https://shot.socialdog.cn/
```

Then smoke-test the changed user path. For model, upload, handoff, or media changes, perform one controlled live run with `MOCK_AI_ENABLED=false`; verify that one upload is not duplicated during retry, the expected result renders, and logs contain no key, signed URL, token, or media bytes. HTTPS health alone is not a complete product acceptance test.

### 6. Record or roll back

After successful verification, append the UTC time, local commit SHA, operator, and backup `DEPLOY_STAMP` to `/opt/soloshot-backups/deployments.log`. Do not put secrets in this log.

For an application-only rollback, first determine that all applied migrations are backward-compatible. Then restore the recorded source snapshot and rebuild:

```bash
rsync -a --delete \
  --exclude 'infra/deployment/.env.production' \
  "/opt/soloshot-backups/<DEPLOY_STAMP>/source/" /opt/soloshot/
cd /opt/soloshot
sudo docker compose \
  -f infra/deployment/docker-compose.production.yml \
  --env-file infra/deployment/.env.production \
  up -d --build --remove-orphans
```

Do not automatically restore `postgres.dump`: a database restore discards newer production writes and requires an explicit outage and data-loss decision. If a migration is not backward-compatible, stop, preserve logs and current data, and agree on the database recovery plan before changing the database. Re-run the external health and changed-path smoke checks after any rollback.

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
