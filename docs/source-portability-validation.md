# Source portability audit — 2026-10-31

Audited the source based on commit `0a681f52`, including first-party binary assets. Found personal checkout paths in 61 tracked files: 58 test project configurations, the script-reload workspace, the Sandbox project and a historical note. Replaced them with workspace-relative paths or commit references. Vendored upstream examples are excluded from the general portability checker; a separate full-tree search found no remaining references to the developer's username.

Changes also quote native archives for paths with spaces, give test fixtures Windows link/toolset configurations, resolve project-relative engine paths against the project directory, add native Windows/Linux source-build entry points and shader compilation, and make the test runner launch fixtures without BeefBuild's space-path `-run` limitation. Script-reload temporary workspaces relocate their engine references. A shutdown regression found during testing is fixed: reflection lookup data survives static destruction and is released at CRT exit.

## Local validation

| Check | Result |
|---|---|
| Linux source with no build cache, under a directory containing spaces | Native libraries/tools, all shipped shader backends and Release launcher built in Ubuntu 22.04 |
| Windows source with no build cache, under a directory containing spaces | Native Windows libraries/tools cross-compiled locally with clang-cl/xwin; Windows Python/Beef source-build driver and shader compilation passed under Wine |
| Quality, Water and ShapeQueries fixtures | Passed on Linux and Windows under Wine |
| Asset-pack integration | Passed on Linux |
| Sandbox engine lookup from another working directory | Project compiled on both platforms with the engine recorded relative to the sample |
| Six structural script-reload generations and clean shutdown | Passed on Linux and Windows under Wine; tracked-memory leak checking remained enabled on Windows |
| Configuration/path audit | Passed; personal checkout paths removed, native archive paths quoted and repository-relative |

No GitHub Actions used for this validation. Native Windows hardware, SDK installation on a fresh Windows machine, audio/device integrations and every test fixture were not exercised. These checks establish build/relocation behavior with the documented prerequisites, not a guarantee for every toolchain or graphics driver. Third-party source is vendored except for the pinned Jolt source fetched by CMake.