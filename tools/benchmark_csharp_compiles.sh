#!/usr/bin/env bash
# .NET gameplay build microbenchmarks; changes only disposable fixture copies.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HOME/TallowBenchmarks/csharp-$(date +%Y%m%d-%H%M%S)"
if (( $# > 0 )); then OUT="$1"; fi
REPEATS="$(printenv REPEATS || echo 3)"
if [[ -z "$REPEATS" ]]; then REPEATS=3; fi
case "$REPEATS" in
    ''|*[!0-9]*) echo "REPEATS must be a positive integer" >&2; exit 2 ;;
esac
if (( REPEATS < 1 || REPEATS > 20 )); then
    echo "REPEATS must be between 1 and 20" >&2; exit 2
fi
if ! command -v dotnet >/dev/null 2>&1; then
    echo "Missing .NET SDK: dotnet not found in PATH" >&2; exit 1
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

{
    echo "Tallow C# compile microbenchmark"
    date -Is
    git -C "$ROOT" rev-parse HEAD
    git -C "$ROOT" status --short
    uname -a
    dotnet --info
    if command -v lscpu >/dev/null 2>&1; then lscpu; fi
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
    fi
} > "$OUT/environment.txt" 2>&1

if [[ ! -d "$ROOT/Tests/CSharpGameplay/src" ]]; then
    echo "Missing Tests/CSharpGameplay/src fixture" >&2; exit 1
fi
echo "phase,iteration,seconds,exit_code,max_rss_kb" > "$OUT/results.csv"

measure() {
    local phase="$1" iteration="$2" name="$1-$2"
    shift 2
    local started stopped status rss=""
    started="$(date +%s%N)"
    if [[ -x /usr/bin/time ]]; then
        if /usr/bin/time -f '%M' -o "$OUT/$name.rss" \
            "$@" > "$OUT/$name.log" 2>&1; then
            status=0
        else
            status=$?
        fi
        rss="$(tr -d '[:space:]' < "$OUT/$name.rss")"
    else
        if "$@" > "$OUT/$name.log" 2>&1; then status=0; else status=$?; fi
    fi
    stopped="$(date +%s%N)"
    local elapsed
    elapsed="$(awk -v a="$started" -v b="$stopped" \
        'BEGIN { printf "%.3f", (b-a)/1000000000 }')"
    printf '%s,%s,%s,%s,%s\n' "$phase" "$iteration" "$elapsed" "$status" "$rss" \
        >> "$OUT/results.csv"
    printf '%-15s run=%-2s elapsed=%6ss status=%s\n' \
        "$phase" "$iteration" "$elapsed" "$status"
    if (( status != 0 )); then
        tail -n 45 "$OUT/$name.log" >&2
        echo "Benchmark failed. Logs are in: $OUT" >&2
        exit "$status"
    fi
}

cd "$ROOT"
# Prepare the build tool outside the timed region.
dotnet build Managed/Tallow.Build/Tallow.Build.csproj -c Debug --nologo \
    > "$OUT/prepare-build-driver.log" 2>&1 || {
        tail -n 45 "$OUT/prepare-build-driver.log" >&2
        exit 1
    }

for (( i=1; i<=REPEATS; i++ )); do
    project="$WORK/run-$i"
    mkdir -p "$project"
    cp -a "$ROOT/Tests/CSharpGameplay/src" "$project/src"
    measure cold "$i" dotnet run --no-build -c Debug \
        --project "$ROOT/Managed/Tallow.Build/Tallow.Build.csproj" \
        -- --project "$project" --engine-root "$ROOT"
    measure noop "$i" dotnet run --no-build -c Debug \
        --project "$ROOT/Managed/Tallow.Build/Tallow.Build.csproj" \
        -- --project "$project" --engine-root "$ROOT"
    # Modify only a disposable copy of the test fixture.
    printf '\n// Tallow benchmark edit %s\n' "$i" >> "$project/src/GameRoot.cs"
    measure warm-edit "$i" dotnet run --no-build -c Debug \
        --project "$ROOT/Managed/Tallow.Build/Tallow.Build.csproj" \
        -- --project "$project" --engine-root "$ROOT"
done

echo
echo "CSV: $OUT/results.csv"
echo "Logs: $OUT/*.log"
if command -v tar >/dev/null 2>&1; then
    tar -czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
    echo "Share this archive: $OUT.tar.gz"
fi
echo "These are .NET CLI timings, not editor Save-to-Play latency."
