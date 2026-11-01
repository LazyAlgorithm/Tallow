# Tallow rename plan (branch-only)

Status: implementation and Linux validation in progress on `rename/tallow`; no rename merged to main.

## Scope
- Tallow Engine, Tallow Editor, and Tallow Manager.
- Clean break across namespaces, serialized component names, manifests, native targets, binaries, tools, workflows, templates, tests, and documentation. No compatibility aliases or old-format readers.
- Keep existing GitHub repository URLs until the coordinated repository rename; preserve historical copyright attribution and third-party identities.
- Keep development on the rename branches. Repository renames and merges remain separate review steps.

## Implemented
- Native source files, CMake targets, static archives, helper tools, and all linker consumers use the Tallow names together.
- Project and runtime manifests are `project.tallow` and `game.tallow`. Templates, saved scenes, generated workspaces, samples, and tests use Tallow names.
- Port the immutable engine identity work from dev: `tallow-version.json`, `tallow-engine.lock.json`, exact-build validation, and automatic pinning of newly created packaged projects.
- Publish matching immutable version IDs and package names; rename-branch CI builds packages without publishing a release.
- Export root PNG from the current SVG master.

## Validation
- Fresh Linux CMake/native and Debug engine/editor/launcher builds pass.
- Strict rename audit and source portability audit pass. Only existing repository URLs and the original copyright notice retain the former name.
- Six immutable version tests pass. Voice, Saving, Scenes, ScriptCatalog, UIDocuments, and asset pack fixtures pass.
- Packaged Showcase creation and compilation pass, including Tallow scripts/components, terrain sidecars, binary assets, immutable project pins, and source-project relocation.
- Windows CI and web runtime validation remain required before merge. Game repository migrations are tracked separately.

## Before cutover
Validate Windows/Linux installation and project packaging, web startup, website links, and each migrated owned game. Coordinate engine and Manager releases, repository URLs, Pages deployment, and public download links. Merge only after explicit approval.
