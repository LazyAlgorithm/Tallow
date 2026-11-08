#!/usr/bin/env bash
# Usage: bash tools/run_engine_bench.sh --pull --preset standard
# Linux Release build + benchmark suite; rebuild if source commit changed.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PULL=0
SKIP_BUILD=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --pull) PULL=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        *) ARGS+=("$arg") ;;
    esac
done

if (( PULL )); then
    git pull --ff-only
fi
for arg in "${ARGS[@]}"; do
    if [[ "$arg" == "--list" || "$arg" == "--help" || "$arg" == "-h" ]]; then
        exec python3 tools/run_engine_bench.py "${ARGS[@]}"
    fi
done

PLAYER="$ROOT/Samples/EcsBench/build/Release_Linux64/EcsBench/EcsBench"
LAUNCHER="$ROOT/build/Release_Linux64/TallowLauncher/TallowLauncher"
STAMP="$ROOT/build/.ecs-engine-bench-build-sha"
REV="$(git rev-parse HEAD)"
DIRTY="$(git status --porcelain --untracked-files=no)"

if (( ! SKIP_BUILD )) && { [[ ! -x "$PLAYER" || ! -x "$LAUNCHER" || ! -f "$STAMP" ]] ||
    [[ "$(cat "$STAMP" 2>/dev/null)" != "$REV" || -n "$DIRTY" ]]; }; then
    echo "Building Tallow Release and EcsBench..."
    ./build.sh --config Release --jobs "${TALLOW_BENCH_BUILD_JOBS:-8}"
    "$LAUNCHER" --build-project Samples/EcsBench
    "${BEEFBUILD:-BeefBuild}" -workspace=Samples/EcsBench -config=Release -platform=Linux64
    mkdir -p build
    printf '%s\n' "$REV" > "$STAMP"
else
    echo "Build is current; using existing EcsBench player."
fi

exec python3 tools/run_engine_bench.py "${ARGS[@]}"
