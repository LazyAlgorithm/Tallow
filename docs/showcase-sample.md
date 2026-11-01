# Exhibition Campus integration validation

The sample is installed from `Editor/templates/showcase` by the launcher's Exhibition Campus choice or `--create FOLDER --showcase`. It recursively copies binary assets and terrain sidecars, and substitutes the project namespace in scripts, prefabs and the saved scene.

Local packaged Linux validation on 2026-10-31 created `RenamedCampus` in a path with spaces, checked all 24 saved station markers and exact binary asset copies, compiled its editor, and ran all exhibit smoke checks successfully (`SHOWCASE_VALID,True`, `authored=True`). The test also relocated an invalid engine path, exercising settings save/reload and preservation of the window size and Escape menu. Run:

```
python3 tools/test_showcase_template.py --package /path/to/Tallow-Linux --play
```

The release workflow runs the creation, asset and compilation checks on both Linux and Windows. The optional rendered run requires a desktop/display and is not run on CI. The source showcase's earlier baseline covered 13 packaged runs; a separate three-process tour test covered client actions, late-join state, spawned impactors, loaded ropes and visible character models. This integration does not establish large-player-count capacity, WAN resilience or minimum hardware requirements.

Template scene SHA-256: `fce11d91821986ce5df84a3ddc16f5c7e33a4ad92b29115410c6f5dd3c11d639`.

The runtime fixes included with this sample address buoyancy during rollback and foliage proxy renderers in editor shading.
