# Third-party licenses and release obligations

Tallow's own source code is available under the [MIT License](LICENSE). That license does **not** replace or relicense its dependencies, assets, fonts, sample content, toolchains, or platform SDKs.

The repository already includes [THIRD_PARTY_LICENSES.txt](THIRD_PARTY_LICENSES.txt), containing the notices and license texts collected for bgfx, bx, bimg, SDL3, Jolt Physics, Recast Navigation, JoltC, ENet, miniaudio, Opus, Dear ImGui, cimgui, ImGuizmo, ImGuiColorTextEdit, cgltf, Assimp, stb, and KEMAR HRTF measurements.

**Distribution:** retain the Tallow MIT LICENSE in engine/source packages and retain THIRD_PARTY_LICENSES.txt in editor and standalone-game packages. Existing `tools/package_engine.py` copies THIRD_PARTY_LICENSES.txt into editor packages; `tools/build_player.py` copies it into game packages if present. Confirm both outputs in release testing.

**Release gate:** audit the actual vendored revisions and all runtime/build-time assets, shaders, fonts, audio samples, precompiled binaries, platform-specific SDKs and transitive dependencies against their upstream license files. Some dependencies use licenses other than MIT. Confirm attribution and any source/offering obligations. Do not describe the entire distribution as MIT-only.

The initial engine copyright line is **Copyright (c) 2026 Tallow contributors**. Before release, confirm this is the appropriate legal copyright holder and that all contributors' rights permit MIT distribution.

The authoritative notices are in THIRD_PARTY_LICENSES.txt, not this summary. This is a release checklist, not legal advice.
