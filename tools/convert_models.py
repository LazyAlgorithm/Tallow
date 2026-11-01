#!/usr/bin/env python3
"""Converts a project's FBX, OBJ, DAE, STL, PLY, 3DS and .blend files to .glb, as the editor does
(docs/model-import.md): the same converters in the same order, the same cache (<project>/.cache/models), then the
import settings kept beside each file. tools/build_player.py uses it to put the converted models in a build.

    python3 tools/convert_models.py <project>      # converts what is out of date, prints what it did
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys

EXTENSIONS = ('.fbx', '.obj', '.dae', '.stl', '.ply', '.3ds', '.blend')

BLENDER_SCRIPT = '''import bpy, sys
args = sys.argv[sys.argv.index('--') + 1:]
source, out = args[0], args[1]
kind = source.lower().rsplit('.', 1)[-1]
if kind == 'fbx': bpy.ops.import_scene.fbx(filepath=source)
elif kind == 'obj': bpy.ops.wm.obj_import(filepath=source)
elif kind == 'stl': bpy.ops.wm.stl_import(filepath=source)
elif kind == 'ply': bpy.ops.wm.ply_import(filepath=source)
bpy.ops.export_scene.gltf(filepath=out, export_format='GLB', export_apply=True, export_animations=True)
'''


def is_converted(name):
    return name.lower().endswith(EXTENSIONS)


def native_folder(engine):
    return engine / 'build' / ('native-win' if os.name == 'nt' else 'native')


def own_tool(engine):
    tool = native_folder(engine) / ('tallow_modelconv.exe' if os.name == 'nt' else 'tallow_modelconv')
    return str(tool) if tool.is_file() else None


def find_blender():
    env = os.environ.get('TALLOW_BLENDER', '')
    if env and Path(env).is_file():
        return env
    found = shutil.which('blender')
    if found:
        return found
    candidates = sorted(Path('C:/Program Files/Blender Foundation').glob('*/blender.exe')) if os.name == 'nt' else [Path('/Applications/Blender.app/Contents/MacOS/Blender')]
    return next((str(c) for c in candidates if c.is_file()), None)


def read_settings(source):
    settings = {'scale': '1', 'zUp': '0', 'animations': '1', 'clips': '', 'materials': '1'}
    path = Path(str(source) + '.import')
    if path.is_file():
        for line in path.read_text(errors='replace').splitlines():
            if '=' in line:
                key, value = line.split('=', 1)
                settings[key.strip()] = value.strip()
    return settings


def source_stamp(source):
    # As the editor writes it (ModelImport.SourceStamp): .NET-style ticks of the file's time, and its size.
    info = source.stat()
    return f'{info.st_mtime_ns // 100 + 621355968000000000}|{info.st_size}\n'


def run_converter(source, out, engine, blender, assimp):
    kind = source.suffix.lower()
    tool = own_tool(engine)
    if kind != '.blend' and tool:
        command = [tool, str(source), str(out)]
    elif kind != '.blend' and assimp and not (kind == '.fbx' and blender):
        command = [assimp, 'export', str(source), str(out), '-fglb2', '-tri', '-jiv', '-gsn', '-lbw', '-embtex']
    elif blender and kind not in ('.dae', '.3ds'):
        script = out.parent / 'tallow_blender_import.py'
        script.write_text(BLENDER_SCRIPT)
        command = [blender, '-b'] + ([str(source)] if kind == '.blend' else ['--factory-startup']) + ['--python', str(script), '--', str(source), str(out)]
    else:
        return 'Blender is needed for .blend files and was not found' if kind == '.blend' else 'no model converter was found (tallow_modelconv, assimp or Blender)'
    result = subprocess.run(command, capture_output=True, text=True, errors='replace')
    if result.returncode != 0 or not out.is_file():
        lines = (result.stdout + result.stderr).strip().splitlines()
        return lines[-1] if lines else f'the converter stopped with status {result.returncode}'
    return None


def convert(project, relative, engine, blender, assimp):
    """Brings <project>/.cache/models/<relative>.glb up to date. Returns (path, error)."""
    source = project / 'src' / relative
    cache = project / '.cache' / 'models'
    converted = cache / (relative + '.glb')
    raw = cache / (relative + '.source.glb')
    converted.parent.mkdir(parents=True, exist_ok=True)
    stamp = source_stamp(source)
    settings_file = Path(str(source) + '.import')
    full_stamp = stamp + (settings_file.read_text(errors='replace') if settings_file.is_file() else '')
    from_file = Path(str(converted) + '.from')
    if converted.is_file() and from_file.is_file() and from_file.read_text(errors='replace') == full_stamp:
        return converted, None
    raw_from = Path(str(raw) + '.from')
    if not raw.is_file() or not raw_from.is_file() or raw_from.read_text(errors='replace') != stamp:
        made = Path(str(raw) + '.part.glb')
        made.unlink(missing_ok=True)
        error = run_converter(source, made, engine, blender, assimp)
        if error:
            return None, error
        os.replace(made, raw)
        raw_from.write_text(stamp)
    settings = read_settings(source)
    tool = native_folder(engine) / ('tallow_modelsettings.exe' if os.name == 'nt' else 'tallow_modelsettings')
    part = Path(str(converted) + '.part')
    if not tool.is_file():
        return None, f'{tool.name} was not found (build the engine native libraries)'
    result = subprocess.run([str(tool), str(raw), str(part), settings['scale'], settings['zUp'], settings['animations'], settings['clips'], settings['materials']], capture_output=True, text=True, errors='replace')
    if result.returncode != 0:
        return None, (result.stderr.strip() or 'the import settings could not be applied')
    os.replace(part, converted)
    from_file.write_text(full_stamp)
    return converted, None


def convert_project(project, engine):
    """Every converted model in the project, up to date: a list of (relative path, .glb path) and a list of errors."""
    blender = find_blender()
    assimp = shutil.which('assimp')
    done, errors = [], []
    src = project / 'src'
    for file in sorted(src.rglob('*')):
        relative = file.relative_to(src)
        if not file.is_file() or not is_converted(file.name) or any(part.startswith('.') for part in relative.parts):
            continue
        path, error = convert(project, relative.as_posix(), engine, blender, assimp)
        if error:
            errors.append(f'{relative.as_posix()}: {error}')
        else:
            done.append((relative.as_posix(), path))
    return done, errors


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    done, errors = convert_project(Path(sys.argv[1]).resolve(), Path(__file__).resolve().parent.parent)
    for relative, _ in done:
        print(f'converted {relative}')
    for error in errors:
        print(f'error: {error}')
    sys.exit(1 if errors else 0)
