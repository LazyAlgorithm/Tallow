#!/usr/bin/env python3
"""Pure-Python regression tests for the hot-reload ELF object cache."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import reload_scripts


class ObjectCacheTests(unittest.TestCase):
    def test_reuses_only_matching_objects_and_host_symbol_sets(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            one = root / 'script.o'
            two = root / 'engine.o'
            one.write_bytes(b'game generation one')
            two.write_bytes(b'unchanged engine')
            calls = []

            def alias(source, target, names):
                calls.append((source.name, frozenset(names)))
                target.write_bytes(source.read_bytes())

            aliases = root / 'aliases'
            with patch.object(reload_scripts, 'alias_host_globals', side_effect=alias):
                objects = [one, two]
                game = [one]
                output, reused = reload_scripts.alias_objects(
                    objects, game, aliases, {'host_func': 10}, {'state': 4})
                self.assertEqual(reused, 0)
                self.assertEqual(len(calls), 2)
                self.assertEqual([p.read_bytes() for p in output],
                                 [b'game generation one', b'unchanged engine'])

                output, reused = reload_scripts.alias_objects(
                    objects, game, aliases, {'host_func': 10}, {'state': 4})
                self.assertEqual(reused, 2)
                self.assertEqual(len(calls), 2)

                one.write_bytes(b'game generation two')
                _, reused = reload_scripts.alias_objects(
                    objects, game, aliases, {'host_func': 10}, {'state': 4})
                self.assertEqual(reused, 1)
                self.assertEqual(len(calls), 3)

                _, reused = reload_scripts.alias_objects(
                    objects, game, aliases, {'host_func': 10, 'new_func': 8},
                    {'state': 4})
                self.assertEqual(reused, 1)
                self.assertEqual(len(calls), 4)

                _, reused = reload_scripts.alias_objects(
                    objects, game, aliases, {'host_func': 10, 'new_func': 8},
                    {'state': 4, 'more_state': 8})
                self.assertEqual(reused, 1)
                self.assertEqual(len(calls), 5)

                output[1].unlink()
                _, reused = reload_scripts.alias_objects(
                    objects, game, aliases, {'host_func': 10, 'new_func': 8},
                    {'state': 4, 'more_state': 8})
                self.assertEqual(reused, 1)
                self.assertEqual(len(calls), 6)


if __name__ == '__main__':
    unittest.main()
