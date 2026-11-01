# Tallow release cutover

Tallow Engine, Editor, Manager and Hub use Tallow namespaces, manifests, native libraries, binaries and release assets. No compatibility aliases or former-format readers are provided.

The engine and Manager compile on Linux. Engine Windows/Linux CI passed, as did native installer checksum and immutable-install checks. The renamed Showcase created, compiled and passed all 24 runtime exhibit checks. Standalone regression fixtures and historical validation artifacts were removed during release cleanup; packaging validation remains in `tools/validate_showcase.py` and `tools/validate_windows_project.py`.

Public repositories are `LazyAlgorithm/Tallow`, `LazyAlgorithm/Tallow-Manager`, `LazyAlgorithm/tallow-hub`, and `LazyAlgorithm/Tallow-Discord-Bot`. Keep main/dev synchronized; gh-pages hosts the website. Games are rebuilt against the immutable release published from this cutover.
