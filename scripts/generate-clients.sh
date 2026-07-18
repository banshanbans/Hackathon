#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

npm run generate:h5
npm run generate:swift
./scripts/generate-python-contracts.sh

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec apps/ios/project.yml --project apps/ios
else
  echo "XcodeGen not found; skipped regenerating apps/ios/SoloShot.xcodeproj" >&2
fi
