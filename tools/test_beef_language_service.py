#!/usr/bin/env python3
"""Exercise the installed Beef compiler against an isolated, unsaved editor workspace."""
from pathlib import Path
import tempfile
import unittest

import beef_language_service as service


class SemanticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='tallow-semantic-tests-')
        cls.project = Path(cls.temporary.name)
        (cls.project / 'src').mkdir()
        (cls.project / 'BeefSpace.toml').write_text('FileVersion = 1\nProjects = {Demo = {Path = "."}}\n')
        (cls.project / 'BeefProj.toml').write_text('FileVersion = 1\nDependencies = {corlib = "*"}\n[Project]\nName = "Demo"\n')
        cls.folder = cls.project / 'request'
        cls.folder.mkdir()
        cls.a = cls.project / 'src/A.bf'
        cls.b = cls.project / 'src/B.bf'
        service._SNAPSHOT_ROOT = cls.project / 'cache'

    @classmethod
    def tearDownClass(cls):
        service.stop_worker()
        service._SNAPSHOT_ROOT = None
        service._SNAPSHOTS.clear()
        service._READ_CACHE.clear()
        cls.temporary.cleanup()

    def setUp(self):
        self.source = 'using System;\nnamespace Demo;\nclass Thing { public int count; public int Other; public void Run() { count = 1; this.count++; } }\n'
        self.a.write_text(self.source)
        self.b.write_text('namespace Demo; class Second { public void Run(Thing t) { t.count++; } public int count; }\n')

    def query(self, mode, source=None, marker='count', name='', target=None, overlays=None):
        target = target or self.a
        source = source if source is not None else target.read_text()
        buffers = dict(overlays or {})
        buffers[target] = source
        rows = [f'operation\t{mode}', f'file\t{target}', f'cursor\t{source.index(marker) + len(marker)}', f'new_name\t{name}']
        for index, (path, text) in enumerate(buffers.items()):
            snapshot = self.folder / f'overlay-{index}.bf'
            snapshot.write_text(text)
            rows.append(f'overlay\t{path}\t{snapshot}')
        (self.folder / 'request.tsv').write_text('\n'.join(rows))
        service.write_response(self.project, self.folder)
        return (self.folder / 'response.tsv').read_text()

    def test_rename_matches_symbol_and_preserves_sources(self):
        result = self.query('rename', name='total')
        self.assertNotIn('error\t', result)
        self.assertEqual(result.count('reference\t'), 4, result)
        self.assertEqual(self.a.read_text(), self.source)
        for line in result.splitlines():
            if line.startswith('snapshot\t'):
                _, original, snapshot = line.split('\t')
                self.assertEqual(Path(original).read_bytes(), Path(snapshot).read_bytes())

    def test_rename_rejects_collisions_keywords_and_capture(self):
        for name in ('Other', 'class'):
            self.assertIn('error\t', self.query('rename', name=name))
        source = self.source.replace('count = 1;', 'int total = 0; count = total;')
        self.assertIn('error\t', self.query('rename', source, name='total'))

    def test_local_rename(self):
        source = self.source.replace('count = 1;', 'int value = 1; count = value;')
        result = self.query('rename', source, marker='value', name='amount')
        self.assertNotIn('error\t', result)
        self.assertEqual(result.count('reference\t'), 2, result)

    def test_unsaved_type_inference_and_member_prefixes(self):
        source = self.source.replace('this.count++;', 'let item = scope String(); item.Ap;')
        result = self.query('completion', source, marker='item.Ap')
        self.assertIn('completion\tAppend', result)
        self.assertNotIn('completion\tOther\t', result)
        for prefix in ('App', 'Appe', 'Appen', 'Ap'):
            result = self.query('completion', source.replace('item.Ap;', f'item.{prefix};'), marker=f'item.{prefix}')
            self.assertIn('completion\tAppend', result)

    def test_symbol_navigation_and_parameters(self):
        result = self.query('definition', marker='this.cou')
        self.assertIn(f'definition\t{self.a}\t2\t25', result)
        result = self.query('symbol', marker='this.cou')
        self.assertIn('signature\t', result)
        self.assertIn('int', result)
        source = self.source.replace('this.count++;', 'this.Run( );')
        self.assertIn('signature\t', self.query('completion', source, marker='this.Run('))
        self.assertIn(f'definition\t{self.a}\t5\t25', self.query('definition', '\n\n\n' + self.source, marker='this.cou'))

    def test_argument_completion_and_signature_help(self):
        source = (
            'namespace Demo; class Thing { '
            'void Use(int first, int second) { } '
            'void Run(int inputValue) { '
            'int localValue = inputValue; '
            'this.Use(localV, inputValue); '
            '} }'
        )
        result = self.query('completion', source, marker='this.Use(localV')
        self.assertIn('completion\tlocalValue\t', result)
        self.assertNotIn('error\t', result)
        result = self.query('signature', source, marker='this.Use(')
        self.assertIn('signature\t', result)
        result = self.query('signature', source, marker='this.Use(localV,')
        self.assertIn('signature\t', result)

    def test_changed_declarations_and_file_switch(self):
        source = self.source.replace('this.count++;', 'this.co;')
        self.assertIn('completion\tcount\t', self.query('completion', source, marker='this.co'))
        added = source.replace('count', 'fresh').replace('this.co', 'this.fr')
        self.assertIn('completion\tfresh\t', self.query('completion', added, marker='this.fr'))
        self.assertNotIn('completion\tcount\t', self.query('completion', added.replace('this.fr', 'this.co'), marker='this.co'))
        second = 'namespace Demo; class Second { public void Run(Thing t) { t.fr; } }'
        result = self.query('completion', second, marker='t.fr', target=self.b, overlays={self.a: added})
        self.assertIn('completion\tfresh\t', result)

    def test_source_graph_changes(self):
        extra = self.project / 'src/C.bf'
        extra.write_text('namespace Demo; class FreshType { public int nice; }')
        source = 'namespace Demo; class Thing { public void Run(FreshType t) { t.ni; } }'
        try:
            self.assertIn('completion\tnice\t', self.query('completion', source, marker='t.ni'))
        finally:
            extra.unlink()
        self.assertNotIn('completion\tnice\t', self.query('completion', source, marker='t.ni'))

    def test_diagnostics_are_complete_after_unchanged_queries(self):
        source = 'namespace Demo; class Thing { public void Run() { MissingType x; } }'
        first = self.query('diagnostics', source, marker='MissingType')
        self.assertIn('\terror\t', first)
        self.assertIn('\twarning\t', first)
        self.assertEqual(first, self.query('diagnostics', source, marker='MissingType'))
        self.b.write_text('namespace Demo; class Second { public int field; }')
        self.assertIn("The variable 'x' is declared but never used", self.query('diagnostics', source, marker='MissingType'))
        fixed = self.query('diagnostics', self.source)
        self.assertNotIn('MissingType', fixed)
        self.assertNotIn("The variable 'x'", fixed)


if __name__ == '__main__':
    unittest.main(verbosity=2)
