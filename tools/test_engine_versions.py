"""Regression tests for Tessera's immutable engine installations."""
import json
from pathlib import Path
import tempfile
import unittest

from engine_versions import LOCK, MANIFEST, install, pin, pin_new, resolve, verify


class EngineVersionsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.package = self.root / 'package'
        self.package.mkdir()
        self.project = self.root / 'project'
        self.project.mkdir()
        self.installed = self.root / 'installed'
        self.data = {'engine': 'Tessera', 'version': '0.1.0',
                     'build': 'a' * 40, 'project_format': 1}
        self.save_manifest()

    def save_manifest(self):
        (self.package / MANIFEST).write_text(json.dumps(self.data))

    def test_pin_install_resolve(self):
        pin(self.project, self.package / MANIFEST)
        target = install(self.package, self.installed)
        self.assertEqual(resolve(self.project, self.installed), target)

    def test_no_automatic_replacement(self):
        install(self.package, self.installed)
        with self.assertRaises(FileExistsError):
            install(self.package, self.installed)

    def test_no_silent_project_migration(self):
        pin(self.project, self.package / MANIFEST)
        self.data['build'] = 'b' * 40
        self.save_manifest()
        with self.assertRaises(ValueError):
            pin(self.project, self.package / MANIFEST)
        self.assertEqual(json.loads((self.project / LOCK).read_text())['build'], 'a' * 40)

    def test_missing_version_is_not_substituted(self):
        pin(self.project, self.package / MANIFEST)
        with self.assertRaises(FileNotFoundError):
            resolve(self.project, self.installed)

    def test_verify_selected_engine(self):
        self.assertFalse(verify(self.project, self.package))
        pin_new(self.project, self.package)
        self.assertTrue(verify(self.project, self.package))
        self.data['build'] = 'b' * 40
        self.save_manifest()
        with self.assertRaises(ValueError):
            verify(self.project, self.package)
        with self.assertRaises(ValueError):
            pin_new(self.project, self.package)

    def test_reject_path_traversal(self):
        self.data['version'] = '../escape'
        self.save_manifest()
        with self.assertRaises(ValueError):
            install(self.package, self.installed)


if __name__ == '__main__':
    unittest.main()
