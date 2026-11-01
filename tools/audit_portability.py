#!/usr/bin/env python3
"""Check first-party source/configuration for personal checkout paths and unportable link settings."""
import os
from pathlib import Path
import re
import subprocess
import tomllib

ROOT = Path(__file__).resolve().parent.parent
PERSONAL_PATH = re.compile(r'/home/(?!runner/|deck/)[^/\s"\x27`]+/|/Users/[^/\s"\x27`]+/|[A-Za-z]:[/\\]Users[/\\][^/\\\s"\x27`]+[/\\]')
EXCLUDED = {'third_party', '.git', 'build', 'dist', '__pycache__', '.tallow-reload'}


def files():
    result = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT, capture_output=True)
    paths = [ROOT / os.fsdecode(name) for name in result.stdout.split(b'\0') if name] if result.returncode == 0 else ROOT.rglob('*')
    return sorted({p for p in paths if p.is_file() and not EXCLUDED.intersection(p.relative_to(ROOT).parts)})


def main():
    failures = []
    count = 0
    for path in files():
        relative = path.relative_to(ROOT)
        try:
            text = path.read_bytes().decode('utf-8', errors='replace')
        except OSError:
            continue
        count += 1
        for number, line in enumerate(text.splitlines(), 1):
            if not (path.name == "audit_portability.py" and line.startswith("PERSONAL_PATH =")) and PERSONAL_PATH.search(line):
                failures.append(f'{relative}:{number}: personal absolute path')
        if path.name not in ('BeefProj.toml', 'BeefSpace.toml'):
            continue
        try:
            config = tomllib.loads(text)
        except tomllib.TOMLDecodeError as error:
            failures.append(f'{relative}: invalid TOML: {error}')
            continue
        for mode, platforms in config.get('Configs', {}).items():
            for platform, settings in platforms.items():
                flags = settings.get('OtherLinkFlags', '')
                for archive in re.findall(r'\$\(WorkspaceDir\)/[^"\s]+\.(?:a|lib)', flags):
                    if '"' + archive + '"' not in flags:
                        failures.append(f'{relative}: {mode}/{platform}: unquoted native archive')
                    workspace = path.parent if relative.parts[0] == 'Tests' else ROOT
                    expanded = archive.replace('$(WorkspaceDir)', str(workspace))
                    normalized = Path(os.path.normpath(expanded))
                    if not normalized.is_relative_to(ROOT / 'build'):
                        failures.append(f'{relative}: {mode}/{platform}: native archive outside repository build/')
    if failures:
        print('\n'.join(failures))
        return 1
    print(f'PASS: {count} first-party files checked (including binary assets); no personal checkout paths; native archive paths are quoted and relative.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
