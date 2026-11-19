#!/usr/bin/env bash
set -euo pipefail
if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  echo "$GITHUB_REF_NAME"
  exit 0
fi
dir="$(cd "$(dirname "$0")/.." && pwd)"
# The C# engine (the 0.3 series): main after the C# cutover (b9f7806e7a11db38ede15adf26cdd1931888fc70). Commits after it count, so the
# first release made from main is v0.3.0-beta and each main commit since is the next. Checked before the ecs rule:
# the branch also contains the ecs baseline.
csharp_baseline=b9f7806e7a11db38ede15adf26cdd1931888fc70
if git -C "$dir" merge-base --is-ancestor "$csharp_baseline" HEAD 2>/dev/null; then
  commits="$(git -C "$dir" rev-list --first-parent --count "$csharp_baseline"..HEAD)"
  if (( commits < 1 )); then
    echo "Unable to derive the 0.3 version" >&2
    exit 1
  fi
  echo "v0.3.$((commits - 1))-beta"
  exit 0
fi
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
