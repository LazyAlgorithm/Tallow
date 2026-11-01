#!/usr/bin/env python3
"""Gathers the licence of every library compiled into Tallow into THIRD_PARTY_LICENSES.txt.

Most of these licences ask that their text accompany anything built with the library, which includes the games
made with the engine: tools/build_player.py copies the file into every packaged game. Run this again after adding
or updating a library; build.sh does.
"""
from pathlib import Path

root = Path(__file__).resolve().parent.parent
tp = root / 'third_party'
jolt_license = next((root / 'build' / native / '_deps/joltphysics-src/LICENSE'
                     for native in ('native', 'native-win')
                     if (root / 'build' / native / '_deps/joltphysics-src/LICENSE').is_file()),
                    root / 'build/native/_deps/joltphysics-src/LICENSE')
libraries = [
    ('bgfx', 'Rendering', tp / 'bgfx.cmake/bgfx/LICENSE'),
    ('bx', 'Base library used by bgfx', tp / 'bgfx.cmake/bx/LICENSE'),
    ('bimg', 'Image library used by bgfx', tp / 'bgfx.cmake/bimg/LICENSE'),
    ('SDL 3', 'Windows, input and gamepads', tp / 'SDL/LICENSE.txt'),
    ('Jolt Physics', 'Physics', jolt_license),
    ('Recast Navigation', 'Polygon navigation baking and Detour path queries', tp / 'recastnavigation/License.txt'),
    ('JoltC', 'C interface to Jolt Physics', tp / 'joltc/LICENSE'),
    ('ENet', 'Network transport', tp / 'enet/LICENSE'),
    ('miniaudio', 'Audio', tp / 'miniaudio/LICENSE'),
    ('Opus', 'Voice chat codec', tp / 'opus/COPYING'),
    ('Dear ImGui', 'Editor and in-game debug interface', tp / 'cimgui/imgui/LICENSE.txt'),
    ('cimgui', 'C interface to Dear ImGui', tp / 'cimgui/LICENSE'),
    ('ImGuizmo', 'Editor gizmos', tp / 'ImGuizmo/LICENSE'),
    ('ImGuiColorTextEdit', 'Editor code view', tp / 'TextEdit/LICENSE'),
    ('cgltf', 'glTF model loading', tp / 'cgltf/LICENSE'),
    ('Assimp', 'Editor model converter (FBX, OBJ, DAE, STL, PLY, 3DS)', tp / 'assimp/LICENSE'),
    ('stb', 'Image and font loading', tp / 'stb/LICENSE'),
]
out = ['Third-party software in Tallow', '=' * 31, '',
       'Tallow, and every game built with it, includes the libraries below. Their licences follow in full.', '']
for name, purpose, _ in libraries:
    out.append(f'  {name:<20} {purpose}')
out += ['  KEMAR HRTF data      Headphone 3D audio', '']
missing = []
for name, purpose, path in libraries:
    out += ['', '-' * 78, name, '-' * 78, '']
    if path.exists():
        out.append(path.read_text(errors='replace').strip())
    else:
        missing.append(str(path))
        out.append(f'(licence file not found at {path.relative_to(root)}; build the native libraries first)')
out += ['', '-' * 78, 'KEMAR HRTF measurements', '-' * 78, '',
        'The head-related impulse responses used for headphone 3D audio were measured on a KEMAR dummy head',
        'microphone at the MIT Media Lab. Copyright 1994 MIT Media Laboratory. Provided free with no restrictions',
        'on use, provided the authors are cited:',
        '',
        '  Gardner, W. G., and Martin, K. D. (1995). HRTF measurements of a KEMAR.',
        '  Journal of the Acoustical Society of America, 97(6), 3907-3908.', '']
(root / 'THIRD_PARTY_LICENSES.txt').write_text('\n'.join(out) + '\n')
print(f'wrote THIRD_PARTY_LICENSES.txt ({len(libraries) + 1} entries)' + (f'; MISSING: {missing}' if missing else ''))
