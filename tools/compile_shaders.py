#!/usr/bin/env python3
"""Compile the engine shaders using the locally built shaderc on Linux or Windows."""
import argparse
import os
from pathlib import Path
import subprocess


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend', action='append', choices=['spirv', 'glsl', 'essl', 'webgl', 'metal'],
                        help='Repeat to select backends; default is every shipped backend.')
    args = parser.parse_args()
    native = 'native-win' if os.name == 'nt' else 'native'
    compiler = os.environ.get('SHADERC', str(root / 'build' / native / 'bgfx/cmake/bgfx' / ('shaderc.exe' if os.name == 'nt' else 'shaderc')))
    source = root / 'Engine/shaders'
    targets = {'spirv': ('spirv', 'linux'), 'glsl': ('430', 'linux'), 'essl': ('310_es', 'android'),
               'webgl': ('300_es', 'asm.js'), 'metal': ('metal', 'osx')}
    failed = []
    # Shaders that are another shader's source with a define added after its first ($input) line: fs_cluster is fs_mesh
    # without lightmaps, which draws from buffers in the stages the lightmaps use (cluster LOD drawing).
    variants = {'fs_cluster': ('fs_mesh.sc', '#define TW_NO_LIGHTMAP 1\n')}
    scratch = root / 'build' / 'shader-variants'
    scratch.mkdir(parents=True, exist_ok=True)
    for name, (original, define) in variants.items():
        lines = (source / original).read_text().split('\n', 1)
        (scratch / (name + '.sc')).write_text(lines[0] + '\n' + define + lines[1])
    for prefix, stage in [('vs_', 'vertex'), ('fs_', 'fragment'), ('cs_', 'compute')]:
        for shader in sorted(list(source.glob(prefix + '*.sc')) + list(scratch.glob(prefix + '*.sc'))):
            if shader.name == 'cs_template.sc':
                continue
            for backend in args.backend or list(targets):
                if backend == 'webgl' and (stage == 'compute' or shader.name.startswith(('vs_cluster', 'cs_clod', 'fs_cluster'))):
                    continue
                profile, platform = targets[backend]
                output = root / 'Engine/assets/shaders' / backend / (shader.stem + '.bin')
                output.parent.mkdir(parents=True, exist_ok=True)
                result = subprocess.run([compiler, '-f', str(shader), '-o', str(output), '--type', stage,
                                         '--platform', platform, '-p', profile, '-i', str(root / 'third_party/bgfx.cmake/bgfx/src'),
                                         '-i', str(source / 'include'), '--varyingdef', str(source / 'varying.def.sc'), '-O', '3'])
                if result.returncode:
                    failed.append(f'{shader.name} ({backend})')
    if failed:
        parser.exit(1, 'Shader compilation failed: ' + ', '.join(failed) + '\n')
    print('Engine shaders compiled successfully.')


if __name__ == '__main__':
    main()
