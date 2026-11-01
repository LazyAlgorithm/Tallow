#!/usr/bin/env python3
"""The macOS link line for Beef projects that use Tallow (docs/macos.md), and a way to add it to their BeefProj.toml.

    python3 tools/macos_link.py --write <BeefProj.toml>...   add or refresh [Configs.Debug.macOS] / [Configs.Release.macOS]

The native archives are named relative to $(WorkspaceDir), the folder of the BeefSpace.toml being built, so the line
works on any machine. Apple's linker searches static archives again until nothing new is found, so they need no
--start-group like on Linux.
"""
import argparse
import os
from pathlib import Path
import re

NATIVE_LIBS = (
    'libtallow_native.a', 'bgfx/cmake/bgfx/libbgfx.a', 'bgfx/cmake/bimg/libbimg.a', 'bgfx/cmake/bimg/libbimg_decode.a',
    'bgfx/cmake/bx/libbx.a', 'SDL/libSDL3.a', 'joltc/libjoltc.a', '_deps/joltphysics-build/libJolt.a', 'enet/libenet.a',
)
# What SDL3 (windows, input, game controllers, audio, file dialogs) and bgfx (Metal) use from the system.
FRAMEWORKS = (
    'Cocoa', 'Foundation', 'CoreFoundation', 'IOKit', 'CoreAudio', 'AudioToolbox', 'CoreVideo', 'CoreMedia', 'AVFoundation',
    'Carbon', 'ForceFeedback', 'GameController', 'CoreHaptics', 'Metal', 'QuartzCore', 'UniformTypeIdentifiers',
)
SYSTEM_LIBS = ('-lc++', '-liconv', '-lm')


def flags(native):
    """The OtherLinkFlags value, with native the build/native folder (a path or a $(WorkspaceDir)-relative one)."""
    parts = ['$(LinkFlags)'] + [f'{native}/{lib}' for lib in NATIVE_LIBS] + list(SYSTEM_LIBS)
    for framework in FRAMEWORKS:
        parts += ['-framework', framework]
    return ' '.join(parts)


def write(project, engine_root):
    text = project.read_text()
    # $(WorkspaceDir) is the folder of the nearest BeefSpace.toml (the Launcher's is the engine's root).
    workspace = next((folder for folder in (project.parent, *project.parent.parents) if (folder / 'BeefSpace.toml').is_file()), project.parent)
    relative = os.path.relpath(engine_root / 'build/native', workspace).replace(os.sep, '/')
    native = f'$(WorkspaceDir)/{relative}'
    rdynamic = ' -rdynamic' if '-rdynamic' in text else ''
    line = flags(native).replace('$(LinkFlags)', '$(LinkFlags)' + rdynamic, 1)
    text = re.sub(r'\n\[Configs\.(Debug|Release)\.macOS\]\n(?:[^\[\n][^\n]*\n?)*', '\n', text).rstrip('\n') + '\n'
    text += f'\n[Configs.Debug.macOS]\nOtherLinkFlags = "{line}"\n\n[Configs.Release.macOS]\nOtherLinkFlags = "{line}"\n'
    project.write_text(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--write', nargs='+', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    for project in args.write:
        write(project.resolve(), root)
        print(f'macOS link line in {project}')


if __name__ == '__main__':
    main()
