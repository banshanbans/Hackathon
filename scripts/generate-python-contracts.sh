#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

output_dir="packages/contracts/generated/python"
rm -rf "$output_dir"

./node_modules/.bin/openapi-generator-cli generate \
  --input-spec packages/contracts/openapi.yaml \
  --generator-name python \
  --output "$output_dir" \
  --global-property models,modelDocs=false,modelTests=false \
  --additional-properties=packageName=soloshot_contracts,packageVersion=1.0.0
