#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

python_bin="${PYTHON_BIN:-}"
if [[ -z "$python_bin" ]]; then
  python_bin="$(command -v python3.12 || true)"
fi

if [[ -z "$python_bin" ]]; then
  echo "Python 3.12 is required. On macOS run: brew install python@3.12" >&2
  exit 1
fi

if [[ ! -x .venv/bin/python ]]; then
  "$python_bin" -m venv .venv
fi

.venv/bin/python -m pip install --disable-pip-version-check -r services/api/requirements.lock
npm_config_cache="${NPM_CONFIG_CACHE:-$repo_root/.cache/npm}" npm ci

echo "Bootstrap complete: $(.venv/bin/python --version), Node $(node --version)"
