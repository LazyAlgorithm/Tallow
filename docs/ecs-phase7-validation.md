# Phase 7 measurements and validation

The runner now supports repeated runs, alternating baseline/current build order, and the existing EcsChecks
suite. This is measurement infrastructure for 7a/7c/7g, not evidence that script performance has improved.
It does not replace the networking, editor, resource-lifetime or mixed-workload acceptance tests.

## Build and run at home

Use a separate checkout for each revision. Build the engine and generate/build EcsBench using that checkout's
launcher and engine, so a baseline project cannot accidentally link the current engine. On Linux:

```sh
./build.sh --config Release
./build/Release_Linux64/TallowLauncher/TallowLauncher --build-project "$PWD/Samples/EcsBench"
BeefBuild -workspace=Samples/EcsBench -config=Release -platform=Linux64
python3 tools/run_ecs_bench.py --check
python3 tools/run_ecs_bench.py --modes gameobject --repeats 3 --output ecs-current-release.jsonl
```

On Windows use `build.ps1 --config Release`, the `Release_Win64` launcher `.exe`, `-platform=Win64`, and
`python` instead of `python3`. Repeat correctness checks with Debug builds and `--config Debug`.
The runner requires a successful check-suite message as well as a zero exit code.

For a comparison, build EcsBench separately in the baseline checkout first, then run from the current checkout:

```sh
python3 tools/run_ecs_bench.py --baseline-project /path/to/baseline/Samples/EcsBench --modes gameobject --repeats 4 --output ecs-comparison.jsonl
```

Use an even repeat count for balanced baseline/current ordering. The default counts are 1k/10k/50k/100k;
`--counts 1000 --frames 120 --repeats 1` is a short smoke run, not an acceptance benchmark.
Omit `--modes gameobject` to also measure explicit ECS and multithreaded ECS.
For the pre-ECS comparison, use a revision that contains the same EcsBench workload (the recorded Phase 1
baseline is `08125074`); a main checkout without EcsBench needs a separately ported equivalent workload.

Results include each run's frame/update averages and p99, spawn time, memory, thread count, revision,
working-tree dirty flag, executable SHA-256 and host/config metadata. Revision metadata describes the checkout;
it cannot prove the executable was rebuilt from that revision. Rebuild explicitly and retain build logs.
Record CPU/GPU models, driver, power mode and compiler version alongside results. Use the same machine,
settings and workload, with unrelated applications closed. The current moving-cube sample is not the full
mixed physics/AI/networked prefab acceptance workload.

The printed table shows medians across runs, including the median of per-run p99 values, **not** a pooled p99.
JSONL preserves every raw per-run summary. Output files must be new, are flushed after each successful run,
and remain available if a later process fails. Missing, duplicate, malformed or mismatched measurements fail
the command instead of silently producing a partial success table. A process timeout also fails the command.

## Checks still required

- Build and run EcsChecks in Debug and Release, including local/private script-history restoration and stale
  script-set rejection. The existing `--check` suite covers these; it is not a multiplayer regression suite.
- Run state-sync and lockstep under delay/jitter/loss; compare hashes, event order, corrections and replay CPU.
  The roadmap's `~/TallowEcsTests` fixtures are outside this repository and were unavailable in this workspace.
- Validate generated visual scripts, scene/prefab round trips, hot reload, and owner/resource cleanup.
- Profile ordinary Mover callbacks, transform reads/writes, dirty propagation and reference refresh before
  selecting an optimization. Report whole-frame and script-update changes separately.
- Run applicable Windows/Linux/macOS/web/mobile checks; record unavailable targets explicitly.

## Work-session validation (2026-11-06)

`python3 -m unittest discover -s tools -p test_run_ecs_bench.py -v`: five runner regression tests pass.
They test scheduling, isolated result files, metric validation and failure handling using synthetic data;
they do not execute Beef or produce engine performance numbers.

The pinned compiler and native archives are now available in this workspace. Linux Debug and Release builds
succeed. The full ECS checks, including generated graph compilation, passed in both configurations in workflow
42264324947. Native editor regression checks and actual compiler-analysis fixtures pass locally. At `3525c548`,
Windows compiler-analysis fixtures and the engine package build pass (workflow 42271437073). These are not
interactive editor or Windows runtime acceptance results.

Graphics-free checks are available after building EcsBench:

```sh
Samples/EcsBench/build/Release_Linux64/EcsBench/EcsBench --check-lifetimes
Samples/EcsBench/build/Release_Linux64/EcsBench/EcsBench --check-references
Samples/EcsBench/build/Release_Linux64/EcsBench/EcsBench --bench-script-cpu 10000 600
```

Use the corresponding Debug/Windows executable for those builds. Lifetime checks cover owned allocations,
subscriptions, stop/restart, removal, unload and safe refusal of live-resource replacement. Reference checks
exercise 65,536 table mutations, removal/re-addition and entity deletion. The reference test reproduced a stale
cached pointer before the native slow-path fix and passes after it.

The CPU benchmark uses the same deterministic Mover workload, warms up 120 updates and reports Scene.Update
average/p99, spawn time, process memory and a position checksum. It resolves world matrices outside the timed
interval to model the cache state left by render extraction. It creates no graphics device, renderer, collision
bodies or AI agents. It does **not** measure whole frames, GPU time, multiplayer or a representative mixed game.
Local cloud-host timings cannot replace the requested reference-PC benchmarks. The initial ECS baseline crashes
at 100k objects because of the cached-reference bug; never report a fabricated baseline measurement for that case.

External multiplayer fixtures, interactive graphics/platform checks, resource migration and the full mixed-workload
performance acceptance remain pending. Phase 7 remains in progress.
