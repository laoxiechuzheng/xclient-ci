#!/usr/bin/env bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_OS:-}" == macOS &&
   "${RUNNER_ENVIRONMENT:-}" == github-hosted && "$(uname -s)" == Darwin ]] || {
  printf '%s\n' '::error::github_hosted_macos_required' >&2
  exit 64
}
script_dir="$(cd -P "$(dirname "$0")" && pwd)"
exec python3 "$script_dir/native_store_smoke.py" "$@" --platform macos
