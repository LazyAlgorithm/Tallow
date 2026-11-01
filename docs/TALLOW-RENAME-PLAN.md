# Tallow rename plan (branch-only)

Status: preparation; no rename merged to main.

## Scope
- Public brand: Tallow Engine, Tallow Editor, Tallow Manager.
- Rename Tessera-owned Beef namespaces, symbols, project/build target names, binaries, UI labels, release assets, GitHub workflows, docs, site and bot branding.
- Preserve existing project file extensions and serialized file formats. Existing projects are developer-owned and can be updated directly; no Tessera compatibility aliases required.
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
- No references to Tessera remain except intentionally preserved format identifiers and historical text.
- Project extensions unchanged.
- Windows/Linux builds and installation/update paths validated.
- No direct commits to main.
