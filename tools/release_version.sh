#!/usr/bin/env bash
set -euo pipefail
if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  echo "$GITHUB_REF_NAME"
  exit 0
fi
dir="$(cd "$(dirname "$0")/.." && pwd)"
baseline=77cc836239cb55477bed593c63b2963a56d3320d
commits="$(git -C "$dir" rev-list --first-parent --count "$baseline"..HEAD)"
if (( commits < 1 )); then
  echo "Unable to derive beta version from main history" >&2
  exit 1
fi
echo "v0.1.$((commits - 1))-beta"
