#!/usr/bin/env python3
"""Pure-Python tests for the Windows side of tools/beef_compile_server.py: finding the Beef sources a Windows
install was built from, and reading what it needs from its DLLs."""
import os
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

import beef_compile_server as server


def fake_pe(path, linked_at, exports=()):
    """A minimal PE file: a header with its link time and, if asked, an export table of the given names."""
    header = 0x80
    names = b''.join(name.encode() + b'\0' for name in exports)
    count = len(exports)
    # One section holding the export directory, the name pointers and the names, at RVA 0x1000 and file offset 0x200.
    directory = 0x1000
    pointers = directory + 40
    strings = pointers + 4 * count
    section = bytearray(40 + 4 * count + len(names))
    struct.pack_into('<I', section, 24, count)
    struct.pack_into('<I', section, 32, pointers)
    offset = strings
    for i, name in enumerate(exports):
        struct.pack_into('<I', section, 40 + 4 * i, offset)
        offset += len(name) + 1
    section[40 + 4 * count:] = names
    data = bytearray(0x200)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 0x3C, header)
    data[header:header + 4] = b'PE\0\0'
    coff = header + 4
    optional_size = 240
    struct.pack_into('<HHI', data, coff, 0x8664, 1, linked_at)
    struct.pack_into('<H', data, coff + 16, optional_size)
    optional = coff + 20
    struct.pack_into('<H', data, optional, 0x20B)
    struct.pack_into('<II', data, optional + 112, directory if exports else 0, len(section))
    table = optional + optional_size
    struct.pack_into('<IIII', data, table + 8, len(section), directory, len(section), 0x200)
    path.write_bytes(bytes(data) + bytes(section))


def git(folder, *args, when=None):
    environment = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t',
                       GIT_COMMITTER_EMAIL='t@t')
    if when is not None:
        environment['GIT_AUTHOR_DATE'] = environment['GIT_COMMITTER_DATE'] = f'{when} +0000'
    return subprocess.run(['git', '-C', str(folder), *args], env=environment, check=True, capture_output=True,
                          text=True).stdout.strip()


class WindowsSourceTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)
        self.clone = self.root / 'Beef'
        self.clone.mkdir()
        git(self.clone, 'init', '-q', '-b', 'master')
        self.commits = []
        for number, corlib in enumerate(('one\n', 'two\n', 'three\n')):
            for path, text in ((f'BeefLibs/corlib/src/System.bf', corlib), ('BeefLibs/Beefy2D/src/App.bf', 'app\n'),
                               ('IDE/src/IDEApp.bf', f'ide {number}\n'), ('BeefBuild/src/BuildApp.bf', f'build {number}\n')):
                file = self.clone / path
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text(text)
            git(self.clone, 'add', '-A')
            git(self.clone, 'commit', '-q', '-m', f'commit {number}', when=1_700_000_000 + number * 1000)
            self.commits.append(git(self.clone, 'rev-parse', 'HEAD'))
        # An install of the second commit's libraries, with Windows line endings, built after the third commit.
        self.install = self.root / 'beef'
        for path, text in (('BeefLibs/corlib/src/System.bf', 'two\r\n'), ('BeefLibs/Beefy2D/src/App.bf', 'app\r\n')):
            file = self.install / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(text.encode())
        (self.install / 'bin').mkdir()
        fake_pe(self.install / 'bin/IDEHelper64.dll', 1_700_000_000 + 5000, ['BfSystem_Create', 'BfCompiler_Compile'])
        self.beef = server.WindowsBeef(self.install / 'bin')

    def tearDown(self):
        self.folder.cleanup()

    def test_finds_the_commit_whose_libraries_the_install_has(self):
        out = self.root / 'out'
        self.assertEqual(server.windows_sources(self.beef, self.clone, out), self.commits[1])
        self.assertEqual((out / 'IDE/src/IDEApp.bf').read_text(), 'ide 1\n')
        self.assertEqual((out / 'BeefBuild/src/BuildApp.bf').read_text(), 'build 1\n')
        self.assertEqual((out / 'commit.txt').read_text().strip(), self.commits[1])

    def test_commits_after_the_compiler_was_built_are_not_candidates(self):
        # Built 200 s after the first commit: the second (1,000 s) is too new even with the 10 minutes allowed.
        fake_pe(self.install / 'bin/IDEHelper64.dll', 1_700_000_000 + 200)
        with self.assertRaises(RuntimeError):
            server.windows_sources(self.beef, self.clone, self.root / 'out')

    def test_a_library_file_the_commit_lacks_is_no_match(self):
        (self.install / 'BeefLibs/corlib/src/Extra.bf').write_text('extra\n')
        with self.assertRaises(RuntimeError):
            server.windows_sources(self.beef, self.clone, self.root / 'out')

    def test_reads_link_time_and_exports(self):
        self.assertEqual(server.pe_time(self.install / 'bin/IDEHelper64.dll'), 1_700_000_000 + 5000)
        self.assertEqual(server.pe_exports(self.install / 'bin/IDEHelper64.dll'), ['BfSystem_Create', 'BfCompiler_Compile'])

    def test_server_name_changes_with_the_compiler(self):
        for name in ('BeefySysLib64.dll', 'BeefBuild.exe'):
            (self.install / 'bin' / name).write_bytes(b'x')
        before = self.beef.server()
        (self.install / 'bin/BeefBuild.exe').write_bytes(b'xy')
        self.assertNotEqual(before, self.beef.server())
        self.assertTrue(before.name.startswith('BeefCompileServer-') and before.suffix == '.exe')

    def test_paths_under_wine(self):
        self.assertEqual(server.WindowsBeef('/b', {}).path(Path('/tmp/a b/c')), 'Z:\\tmp\\a b\\c')
        self.assertEqual(server.WindowsBeef('/b', {}).prefix(), ['wine'])
        self.assertEqual(server.WindowsBeef('/b').prefix(), [])


if __name__ == '__main__':
    unittest.main()
