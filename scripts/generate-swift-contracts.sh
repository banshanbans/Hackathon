#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

output_dir="packages/contracts/generated/swift/OpenAPIGenerated"
duplicate_backup="$(mktemp -d)"
trap 'rm -rf "$duplicate_backup"' EXIT

if [[ -d "$output_dir" ]]; then
  find "$output_dir" -maxdepth 1 -type f -name '* 2*' -exec cp -p {} "$duplicate_backup"/ \;
fi

rm -rf "$output_dir"

./node_modules/.bin/openapi-generator-cli generate \
  --input-spec packages/contracts/openapi.yaml \
  --generator-name swift6 \
  --output "$output_dir" \
  --global-property models,modelDocs=false,modelTests=false,supportingFiles \
  --additional-properties=projectName=SoloShotContracts,useSPMFileStructure=true,validatable=true

if find "$duplicate_backup" -mindepth 1 -print -quit | grep -q .; then
  find "$duplicate_backup" -maxdepth 1 -type f -exec cp -p {} "$output_dir"/ \;
fi
