#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

output_dir="packages/contracts/generated/swift/OpenAPIGenerated"
rm -rf "$output_dir"

./node_modules/.bin/openapi-generator-cli generate \
  --input-spec packages/contracts/openapi.yaml \
  --generator-name swift6 \
  --output "$output_dir" \
  --global-property models,modelDocs=false,modelTests=false,supportingFiles \
  --additional-properties=projectName=SoloShotContracts,useSPMFileStructure=true,validatable=true
