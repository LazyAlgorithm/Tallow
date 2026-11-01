# Tallow rename plan (branch-only)

Status: preparation; no rename merged to main.

## Scope
- Public brand: Tallow Engine, Tallow Editor, Tallow Manager.
- Rename Tessera-owned Beef namespaces, symbols, project/build target names, binaries, UI labels, release assets, GitHub workflows, docs, site and bot branding.
- Breaking rename is approved: migrate all four developer-owned projects, project filenames, serialized formats, namespaces, scripts and tooling to Tallow. No backward-compatibility aliases or readers are required.
- Avoid renaming third-party dependencies, historical attribution, and unrelated references.

## Execution
1. Inventory Tessera references and classify brand vs code vs format.
2. Rename engine source and build configuration on rename/tallow.
3. Update manager dependency, catalog, release lookup and UI on rename/tallow.
4. Update CI/release workflows, docs, site, and Discord bot references.
5. Build and smoke-test engine/editor/manager on supported platforms and test owned projects.
6. Rename GitHub repositories only after review; update all cross-repo URLs and GitHub Pages.
7. Merge only after explicit approval; do not change main during development.

## Review gates
- No Tessera branding, source identifiers, or engine-owned filenames remain. Preserve only external GitHub URLs until the repository rename, third-party attributions, and required native-library names until their build definitions are updated.
- New projects and migrated projects use Tallow-named file extensions and metadata; older formats need not load.
- Windows/Linux builds and installation/update paths validated.
- No direct commits to main.

## Clean-break file format migration gate
The old project and game manifests are now called `project.tallow` and `game.tallow` in the launcher entry point and player packager. Before merging, inspect and change **every** reader, writer, template, test, example, asset pack index, editor, and CI script using the previous filenames. The renamed branch is not build-verified at this stage.

Do not rename binary/native ABI artifacts independently of their CMake producers and consumers. Rebuild all four developer-owned projects after their generated Beef workspaces, imports, assets, and manifests have been converted.

Validation required: repository-wide `python3 tools/audit_tallow_rename.py --strict`, Linux/Windows build, new-project creation, existing-project open, game packaging, web player startup, and the website links.
