# Versioned installation and project compatibility

Status: implementation plan. No existing engine installations or project files are changed by this document.

## Scope and release rules

- Keep `main`, `dev`, `release`, and temporarily `gh-pages` in Tessera. Keep `main`, `dev`, and `release` in tessera-hub.
- Do not delete `gh-pages` or change the website deployment until a replacement is proven.
- Do not delete branches with unmerged changes before reviewing and preserving their commits.
- Treat benchmark branches, backup branches, generated artifacts, and forks as candidates for review, not as proof that their contents are disposable.
- No automatic engine updates. No silent project migration. Keep versions side by side.

## Existing code to reuse

- Tessera: `tools/package_engine.py` packages portable editor distributions and already stages output atomically.
- Tessera: `docs/coding-style.md` is authoritative for Beef naming, layout, comments, and file organisation. Run `python3 tools/format/format_code.py --check` on touched Beef code.
- Tessera Hub: `src/Core/` implements catalog retrieval, dependency detection and installation, checksum-verified downloads, library tracking, and recovery. Reuse these implementations rather than recreating them.
- Tessera Hub: `src/Scripts/HubUi.bf`, `src/UI/hub.tui`, and `src/UI/hub.tcss` are the visual reference for all new graphical installation/management surfaces.
- Hub remains a separate distribution tool for testing and games; the official Tessera installer must not require Hub.

## Installation identity and layout

Publish immutable engine packages with a semantic version, platform, architecture, full source commit SHA, package SHA-256, and project format compatibility number. A mutable channel name (`dev`, `release`) is not an installation identity.

Use side-by-side directories keyed by version plus immutable build identifier, for example `versions/0.1.0/<commit>/`. Track installations in an atomic local registry with package hashes and ownership metadata. Never delete user projects, shared dependencies, or unrelated installations on uninstall.

Install to a staging directory, verify hashes and expected contents, then atomically move into the version directory. If a step fails, retain the existing installation. Request consent before installing missing system dependencies. The standalone installer must run on clean Windows and Linux systems without Beef already installed, as demonstrated by existing Tessera Hub builds.

## Project pinning

Add an engine lockfile to each project with engine name, semantic version, immutable build identifier, and project format version. Resolve the exact installed engine before launching or compiling the project. An unavailable version offers an explicit install or locate action; it must not silently substitute the newest version.

If an explicitly chosen different version requires migration, display the changes, back up the project, migrate only after confirmation, and retain a way to return to the original. Separate generated caches by engine build identifier.

## Deliverables

1. Shared, reusable installation core derived from Hub's working dependency and download code, without breaking Hub's game workflows.
2. Version manifest generation and checksums integrated with `tools/package_engine.py` and release workflows.
3. Standalone Windows and Linux installer builds using Hub's established visual style.
4. Optional version manager using the same installation core, with install, launch, locate, uninstall, and default-for-new-projects actions.
5. Project lockfile read/write and exact-version resolution in the Tessera launcher/editor.
6. Tests for clean installs, parallel versions, missing dependencies, hash failures, interrupted installs, uninstall safety, pinning, and migration refusal.
7. Only after verification, repository cleanup and branch deletion using an authenticated GitHub operation that supports ref deletion.

## Implementation constraints

Keep modifications on `dev` until reviewed. Preserve `main`, `release`, and `gh-pages`. Do not update installed engines automatically, including from a Hub catalog refresh. Display available versions without installing them. Ensure all new Beef code follows Tessera's existing code style and all new visual interfaces match Hub's theme and controls.
