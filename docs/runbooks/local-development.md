# Local development runbook

## First setup

1. Install Python 3.12 and XcodeGen on macOS: `brew install python@3.12 xcodegen`.
2. Start Docker Desktop.
3. Run `make bootstrap` and `make generate`.
4. Copy `.env.example` to `.env`; local Make targets do this automatically when starting infrastructure.

## Start W0 services

- `make dev-infra` starts PostgreSQL, Redis, MinIO, and the bucket initializer.
- `make infra-status` shows dependency health.
- `make dev-api` starts FastAPI on port 8000.
- `make dev-h5` starts Vite on port 5173.

W0 intentionally exposes only `/health`. A 404 from `/api/v1` routes is correct until their owning work package is implemented.

## Common recovery

- Docker connection failure: start Docker Desktop, then rerun `make dev-infra`.
- Port conflict: stop the conflicting local service rather than changing shared contract URLs silently.
- Generated code drift: run `make generate`, inspect the contract change, and commit both contract and generated output.
- Missing simulator device runtime: use `make test-ios`, which builds for the generic iOS Simulator destination without booting a device.
- Missing Xcode iOS platform component: install the matching iOS platform from Xcode Settings > Components first. The SDK may appear in `xcodebuild -showsdks`, but Xcode cannot select even a generic destination until the platform component is registered.
