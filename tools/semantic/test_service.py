"""Integration checks against the actual pinned compiler, not a mock completion list."""
import argparse
import os
from pathlib import Path
import tempfile
from service import Worker, Session


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--beef-root', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='tallow-semantic-') as tmp:
        root = Path(tmp)
        source = root / 'Fixture.bf'
        text = '''using System;
namespace Fixture;
class Parent {
/// Distance in metres.
public int inherited; public float Calculate(int x) => x; public float Calculate(float x) => x; }
class Child<T> : Parent { public T value; }
class Program { public static void Main() { let child = scope Child<int>(); child.inherited = 1; } }
'''
        source.write_text(text)
        platform = 'Win64' if os.name == 'nt' else 'Linux64'
        macros = 'BF_64_BIT\nBF_LITTLE_ENDIAN\nBF_MACHINE_X64\nDEBUG\n'
        macros += 'BF_PLATFORM_WINDOWS' if os.name == 'nt' else 'BF_PLATFORM_LINUX\nBF_PLATFORM_POSIX'
        os.environ['TALLOW_BEEF_DIST'] = str(args.beef_root.resolve() / ('bin' if os.name == 'nt' else 'IDE/dist'))
        corlib = args.beef_root.resolve() / 'BeefLibs/corlib'
        projects = {'corlib': dict(path=corlib, defines=macros, startup='', target=2, dependencies=[],
                                  files=sorted((corlib / 'src').rglob('*.bf'))),
                    'Fixture': dict(path=root, defines=macros, startup='Fixture.Program', target=0,
                                    dependencies=['corlib'], files=[source])}
        worker = Worker(args.helper.resolve())
        try:
            session = Session(worker, projects, platform)
            def resolve(content, revision, cursor, kind='completion'):
                return session.resolve(dict(id=revision, generation=1, path=str(source), cursor=cursor, kind=kind,
                                            buffers=[dict(path=str(source), revision=revision, text=content)]))
            result = resolve(text, 1, text.index('child.inherited') + len('child.'))
            assert {'inherited', 'value', 'Calculate'} <= set(result['completions']), result
            result = resolve(text, 2, text.index('child.inherited') + len('child.inh'), 'definition')
            assert result['definition']['path'] == str(source) and result['definition']['line'] == 4, result
            result = resolve(text, 9, text.index('child.inherited') + len('child.inh'), 'hover')
            assert any('Distance in metres.' in doc for doc in result['documentation']), result
            signature = text.replace('child.inherited = 1;', 'child.Calculate(1);')
            result = resolve(signature, 3, signature.index('child.Calculate(1') + len('child.Calculate('))
            assert len(result['signatures']) == 2 and any('int x' in s for s in result['signatures']), result
            bad = text.replace('child.inherited = 1;', 'child.inherited = "wrong";')
            result = resolve(bad, 4, -1, 'diagnostics')
            assert any("Unable to implicitly cast 'System.String' to 'int'" in d['message'] for d in result['diagnostics']), result
            assert source.read_text() == text, 'Analysis must never overwrite saved source'
            result = resolve(text, 5, -1, 'diagnostics')
            assert not [d for d in result['diagnostics'] if not d['warning']], result
            assert result['revision'] == 5 and result['versions'][str(source)] == 5, result
            malformed = text.replace('child.inherited = 1;', 'child.inherited = ;')
            result = resolve(malformed, 7, -1, 'diagnostics')
            assert any(not d['warning'] for d in result['diagnostics']), result
            result = resolve(text, 8, -1, 'diagnostics')
            assert not [d for d in result['diagnostics'] if not d['warning']], result
            try:
                resolve(text, 6, len(text.encode()) + 1)
            except ValueError:
                pass
            else:
                raise AssertionError('Out-of-buffer cursor accepted')
        finally:
            worker.close()
    print('Beef semantic integration checks passed')


if __name__ == '__main__':
    main()
