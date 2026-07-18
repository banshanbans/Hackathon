PYTHON := .venv/bin/python
RUFF := .venv/bin/ruff
MYPY := .venv/bin/mypy
PYTEST := .venv/bin/pytest
COMPOSE := docker compose -f infra/docker-compose.yml --env-file .env

.PHONY: bootstrap dev-infra infra-status migrate dev-api dev-h5 generate seed-demo lint typecheck test test-api test-api-integration test-h5 test-contracts evals e2e-h5 test-ios e2e-handoff

IOS_SIMULATOR_NAME ?= iPhone 17 Pro

bootstrap:
	./scripts/bootstrap.sh

dev-infra:
	@test -f .env || cp .env.example .env
	$(COMPOSE) up -d --wait postgres redis minio
	$(COMPOSE) run --rm --no-deps minio-init

infra-status:
	$(COMPOSE) ps

migrate:
	PYTHONPATH=services/api $(PYTHON) -m alembic -c alembic.ini upgrade head

dev-api:
	PYTHONPATH=services/api $(PYTHON) -m uvicorn app.main:app --reload --host 127.0.0.1 --port 8000

dev-h5:
	npm run dev --workspace @soloshot/h5

generate:
	./scripts/generate-clients.sh

seed-demo:
	npm run assets:test-image --workspace @soloshot/h5

lint:
	$(RUFF) check services/api infra/migrations
	npm run lint --workspace @soloshot/h5

typecheck:
	$(MYPY) services/api/app services/api/tests
	npm run typecheck --workspace @soloshot/h5

test-api:
	PYTHONPATH=services/api $(PYTEST) services/api/tests/unit

test-api-integration: migrate
	RUN_POSTGRES_TESTS=1 PYTHONPATH=services/api $(PYTEST) services/api/tests/integration

test-h5:
	npm run test --workspace @soloshot/h5
	npm run build --workspace @soloshot/h5

test-contracts:
	PYTHONPATH=services/api $(PYTEST) services/api/tests/contract
	npm run test:contracts --workspace @soloshot/h5
	swift test --disable-sandbox --package-path packages/contracts/generated/swift

evals:
	PYTHONPATH=services/api $(PYTEST) services/api/tests/evals

e2e-h5:
	npm run test:e2e --workspace @soloshot/h5

e2e-handoff:
	PYTHONPATH=services/api $(PYTEST) services/api/tests/unit/test_w3_handoff.py
	npm run test:e2e --workspace @soloshot/h5 -- --grep "H5 handoff"

test: test-api test-contracts test-h5

test-ios:
	xcodegen generate --spec apps/ios/project.yml --project apps/ios
	xcodebuild test -project apps/ios/SoloShot.xcodeproj -scheme SoloShot -destination 'platform=iOS Simulator,OS=latest,name=$(IOS_SIMULATOR_NAME)' CODE_SIGNING_ALLOWED=NO
	xcodebuild -project apps/ios/SoloShot.xcodeproj -scheme SoloShot -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
