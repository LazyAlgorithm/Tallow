#!/usr/bin/env bash
# Run from an up-to-date ecs-ai-navigation worktree. Builds this checkout's
# native/Beef engine and test sample, then runs ECS/AI regression checks and
# a small mixed prefab/BT/networked-object smoke benchmark.
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
project="$root/Samples/EcsBench"
log="$root/ecs-ai-navigation-test.log"
cd "$root"

: > "$log"
exec > >(tee -a "$log") 2>&1
trap 'echo; echo "AI/ECS test log: $log"' EXIT

echo "Tallow ECS AI/Navigation smoke and regression tests"
echo "Revision: $(git rev-parse --short HEAD)"
echo "Repository: $root"

if [[ -z "${BEEFBUILD:-}" ]]; then
    if command -v BeefBuild >/dev/null 2>&1; then
        export BEEFBUILD="$(command -v BeefBuild)"
    elif [[ -x "$HOME/.local/share/TallowBuildTools/beef/IDE/dist/BeefBuild.sh" ]]; then
        export BEEFBUILD="$HOME/.local/share/TallowBuildTools/beef/IDE/dist/BeefBuild.sh"
    else
        echo "ERROR: BeefBuild was not found. Add it to PATH or export BEEFBUILD=/path/to/BeefBuild." >&2
        exit 1
    fi
fi
echo "Compiler: $BEEFBUILD"

if [[ "${1:-}" == "--reuse-native" ]]; then
    echo
    echo "== Reusing completed native libraries, compiling Beef launcher and test binaries =="
    if [[ ! -f "$root/build/native/libtallow_native.a" ]]; then
        echo "ERROR: Native libraries missing. Rerun without --reuse-native." >&2
        exit 1
    fi
    ./build.sh --config Debug --skip-native --skip-shaders
elif [[ "${1:-}" != "--quick" ]]; then
    echo
    echo "== Building Tallow launcher and native dependencies (first checkout build may take longer) =="
    ./build.sh --config Debug --skip-shaders
else
    echo
    echo "== Reusing a previously built launcher (--quick) =="
fi

launcher="$root/build/Debug_Linux64/TallowLauncher/TallowLauncher"
if [[ ! -x "$launcher" ]]; then
    echo "ERROR: No built launcher at $launcher. Rerun without --quick." >&2
    exit 1
fi

echo
echo "== Generating the EcsBench Beef project =="
"$launcher" --build-project "$project"

echo
echo "== Building EcsBench Release/Linux64 =="
"$BEEFBUILD" "-workspace=$project" "-config=Release" "-platform=Linux64"

bench="$project/build/Release_Linux64/EcsBench/EcsBench"
if [[ ! -x "$bench" ]]; then
    echo "ERROR: EcsBench executable missing: $bench" >&2
    exit 1
fi

echo
echo "== ECS/AI/navigation regression checks (must finish with ALL PASSED) =="
(
    cd "$project"
    TALLOW_BENCH_MODE=check "$bench" --project "$project"
)

echo
echo "== Mixed GameObject/ECS/Behavior Tree/NetworkIdentity smoke (200 objects) =="
(
    cd "$project"
    TALLOW_BENCH_MODE=mixed TALLOW_BENCH_COUNT=200 TALLOW_BENCH_FRAMES=120 \
        "$bench" --project "$project"
)

echo
echo "== AI crowd smoke: 200 Behavior Trees, Navigation Agents and nearby targets =="
crowd_result="$root/ecs-ai-crowd-smoke.jsonl"
rm -f "$crowd_result"
(
    cd "$project"
    TALLOW_BENCH_MODE=ai TALLOW_BENCH_COUNT=200 TALLOW_BENCH_FRAMES=90 \
        TALLOW_BENCH_OUT="$crowd_result" "$bench" --project "$project"
)
python3 - "$crowd_result" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
if not path.is_file():
    sys.exit('ERROR: AI crowd benchmark produced no result JSON.')
rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
if len(rows) != 1 or rows[0].get('mode') != 'ai':
    sys.exit('ERROR: expected exactly one AI crowd result.')
result = rows[0]
if result.get('ai_agents') != 200 or result.get('behavior_trees') != 200 or result.get('ai_tree_ticks', 0) <= 0:
    sys.exit('ERROR: AI crowd did not initialize and tick all expected agents.')
print('PASS: 200 AI agents, 200 trees, active behavior ticks and navigation benchmark completed')
PY

echo
echo "ALL TEST COMMANDS PASSED"
echo "Please share ecs-ai-navigation-test.log and ecs-ai-crowd-smoke.jsonl."
