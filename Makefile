PYTHON := .venv/bin/python
RUFF := .venv/bin/ruff
MYPY := .venv/bin/mypy
PYTEST := .venv/bin/pytest
COMPOSE := docker compose -f infra/docker-compose.yml --env-file .env

.PHONY: bootstrap dev-infra infra-status dev-api dev-h5 generate lint typecheck test test-api test-h5 test-contracts test-ios

bootstrap:
	./scripts/bootstrap.sh

dev-infra:
	@test -f .env || cp .env.example .env
	$(COMPOSE) up -d --wait postgres redis minio
	$(COMPOSE) run --rm --no-deps minio-init

infra-status:
	$(COMPOSE) ps

dev-api:
	PYTHONPATH=services/api $(PYTHON) -m uvicorn app.main:app --reload --host 127.0.0.1 --port 8000

dev-h5:
	npm run dev --workspace @soloshot/h5

generate:
	./scripts/generate-clients.sh

lint:
	$(RUFF) check services/api
	npm run lint --workspace @soloshot/h5

typecheck:
	$(MYPY) services/api/app services/api/tests
	npm run typecheck --workspace @soloshot/h5

test-api:
	PYTHONPATH=services/api $(PYTEST) services/api/tests/unit

test-h5:
	npm run test --workspace @soloshot/h5
	npm run build --workspace @soloshot/h5

test-contracts:
	PYTHONPATH=services/api $(PYTEST) services/api/tests/contract
	npm run test:contracts --workspace @soloshot/h5
	swift test --disable-sandbox --package-path packages/contracts/generated/swift

test: test-api test-contracts test-h5

test-ios:
	xcodegen generate --spec apps/ios/project.yml --project apps/ios
	xcodebuild -project apps/ios/SoloShot.xcodeproj -scheme SoloShot -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
