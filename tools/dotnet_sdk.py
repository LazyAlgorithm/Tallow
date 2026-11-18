"""The released .NET SDK Tallow pins (Editor/src/Project/DotNetSdk.bf PinnedVersion), for the Python tools.

The dotnet on PATH is used when it has a released SDK of that version or newer (one install of .NET is enough).
Otherwise the launcher and editor use Tallow's own copy (`TallowLauncher --install-dotnet`, or the prompt at start)
by putting it first on PATH and in DOTNET_ROOT for everything they start. `apply()` does the same for a tool run
from a terminal, so engine builds, exports and tests use a released SDK and runtime rather than a preview the
system has. Importing this module applies it.

    TALLOW_DOTNET_HOME   the folder holding each installed version (as for the launcher)
    TALLOW_SYSTEM_DOTNET=1   use the dotnet on PATH as it is
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def pinned() -> str:
    text = (ROOT / 'Editor/src/Project/DotNetSdk.bf').read_text(encoding='utf-8')
    found = re.search(r'PinnedVersion\s*=\s*"([^"]+)"', text)
    if not found:
        raise SystemExit('Editor/src/Project/DotNetSdk.bf has no PinnedVersion.')
    return found.group(1)


def home() -> Path:
    if os.environ.get('TALLOW_DOTNET_HOME'):
        return Path(os.environ['TALLOW_DOTNET_HOME'])
    if sys.platform == 'win32':
        return Path(os.environ.get('LOCALAPPDATA', Path.home() / 'AppData/Local')) / 'Tallow/dotnet'
    if sys.platform == 'darwin':
        return Path.home() / 'Library/Application Support/Tallow/dotnet'
    return Path(os.environ.get('XDG_DATA_HOME') or Path.home() / '.local/share') / 'Tallow/dotnet'


def root() -> Path:
    return home() / pinned()


def installed() -> bool:
    folder = root()
    return (folder / ('dotnet.exe' if sys.platform == 'win32' else 'dotnet')).is_file() and (folder / 'sdk' / pinned()).is_dir()


def _numbers(version: str) -> list[int]:
    return [int(part) if part.isdigit() else 0 for part in version.split('-')[0].split('.')]


def path_has_released() -> bool:
    """Whether the dotnet on PATH has a released SDK of the pinned major, the pinned version or newer (then it is
    used as it is: one install of .NET is enough)."""
    found = shutil.which('dotnet')
    if not found:
        return False
    try:
        listing = subprocess.run([found, '--list-sdks'], capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    want = pinned()
    for line in listing.splitlines():
        version = line.split(' ')[0].strip()
        if version.split('.')[0] == want.split('.')[0] and '-' not in version and _numbers(version) >= _numbers(want):
            return True
    return False


def path_sdk_is_prerelease() -> bool:
    found = shutil.which('dotnet')
    if not found:
        return False
    try:
        version = subprocess.run([found, '--version'], capture_output=True, text=True, timeout=60).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return False
    return '-' in version


def apply() -> bool:
    """Puts Tallow's copy of the pinned SDK first on PATH and in DOTNET_ROOT when it is installed and the dotnet on
    PATH has no released one as new (what the launcher does)."""
    if os.environ.get('TALLOW_SYSTEM_DOTNET') == '1' or not installed() or path_has_released():
        return False
    folder = str(root())
    path = os.environ.get('PATH', '')
    if not path.startswith(folder + os.pathsep):
        os.environ['PATH'] = folder + os.pathsep + path
    os.environ['DOTNET_ROOT'] = folder
    # A launcher this tool starts finds the same copy, even with its own XDG_DATA_HOME (tests keep their settings
    # in a scratch folder).
    os.environ['TALLOW_DOTNET_HOME'] = str(home())
    os.environ.setdefault('DOTNET_NOLOGO', '1')
    return True


def require_release() -> None:
    """apply(), else stop when the dotnet on PATH is a pre-release: builds and exports use a released SDK."""
    if apply() or os.environ.get('TALLOW_SYSTEM_DOTNET') == '1':
        return
    if path_sdk_is_prerelease():
        raise SystemExit(f'The dotnet on PATH is a pre-release SDK. Install the released one Tallow uses ({pinned()}): '
                         'run TallowLauncher --install-dotnet (or set TALLOW_SYSTEM_DOTNET=1 to use it anyway).')


apply()
