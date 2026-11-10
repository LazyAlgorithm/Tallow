#!/usr/bin/env bash
set -euo pipefail
if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  echo "$GITHUB_REF_NAME"
  exit 0
fi
dir="$(cd "$(dirname "$0")/.." && pwd)"
# The ECS engine (the ecs branch, and branches made from it) is the 0.2 series: v0.2.0-beta is the first commit after
# this one, where Phase 7 was finished. Everything else counts from main's baseline as the 0.1 series.
ecs_baseline=4d6a16ce9440264962f6701ae9a91a912f3ec152
if git -C "$dir" merge-base --is-ancestor "$ecs_baseline" HEAD 2>/dev/null; then
  commits="$(git -C "$dir" rev-list --first-parent --count "$ecs_baseline"..HEAD)"
  if (( commits < 1 )); then
    echo "Unable to derive beta version from ecs history" >&2
    exit 1
  fi
  echo "v0.2.$((commits - 1))-beta"
  exit 0
fi
baseline=77cc836239cb55477bed593c63b2963a56d3320d
commits="$(git -C "$dir" rev-list --first-parent --count "$baseline"..HEAD)"
if (( commits < 1 )); then
  echo "Unable to derive beta version from main history" >&2
  exit 1
fi
echo "v0.1.$((commits - 1))-beta"
