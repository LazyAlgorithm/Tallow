#!/usr/bin/env python3
"""Pure-Python regression tests for the hot-reload ELF object cache."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import reload_scripts


class LinkPipelineTests(unittest.TestCase):
    def test_persistent_platform_workspaces(self):
        root = Path('/tmp/MyGame')
        self.assertEqual(reload_scripts.reload_workspace(root, 'linux'),
                         root / '.tallow-reload/workspace-linux64')
        self.assertEqual(reload_scripts.reload_workspace(root, 'windows'),
                         root / '.tallow-reload/workspace-win64')

    def test_game_objects_explicit_and_deps_archived(self):
        one, dep, two = [Path(name) for name in ('game-one.o', 'engine.o', 'game-two.o')]
        prepared = [Path(name) for name in ('prepared-one.o', 'prepared-engine.o', 'prepared-two.o')]
        game, dependencies = reload_scripts.partition_link_objects(
            [one, dep, two], prepared, [one, two])
        self.assertEqual(game, [prepared[0], prepared[2]])
        self.assertEqual(dependencies, [prepared[1]])

    def test_archive_reused_until_dependency_changes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            obj = root / 'engine.o'
            obj.write_bytes(b'first')
            archive = root / 'resident-dependencies.a'
            invocations = []

            def build(args, check):
                self.assertEqual(args[:2], ['ar', 'rcs'])
                invocations.append(args)
                Path(args[2]).write_bytes(b'archived')

            with patch.object(reload_scripts.subprocess, 'run', side_effect=build):
                result, reused = reload_scripts.cached_dependency_archive([obj], archive)
                self.assertEqual(result, archive)
                self.assertFalse(reused)
                self.assertEqual(len(invocations), 1)
                result, reused = reload_scripts.cached_dependency_archive([obj], archive)
                self.assertTrue(reused)
                self.assertEqual(len(invocations), 1)
                obj.write_bytes(b'changed content with different length')
                result, reused = reload_scripts.cached_dependency_archive([obj], archive)
                self.assertFalse(reused)
                self.assertEqual(len(invocations), 2)

    def test_no_dependency_archive_needed(self):
        with tempfile.TemporaryDirectory() as folder:
            result, reused = reload_scripts.cached_dependency_archive(
                [], Path(folder) / 'empty.a')
            self.assertIsNone(result)
            self.assertFalse(reused)


class ObjectCacheTests(unittest.TestCase):
    def test_reuses_only_matching_objects_and_host_symbol_sets(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            one = root / 'script.o'
            two = root / 'engine.o'
            one.write_bytes(b'game generation one')
            two.write_bytes(b'unchanged engine')
            calls = []

            def relevant(data, names):
                declared = {'state', 'more_state'} if b'game' in data else {'host_func', 'new_func'}
                return sorted(declared.intersection(names))

            def alias(source, target, names):
                calls.append((source.name, frozenset(names)))
                data = source.read_bytes()
                target.write_bytes(data)
                return relevant(data, names)

            aliases = root / 'aliases'
            with patch.object(reload_scripts, 'alias_host_globals', side_effect=alias), \
                    patch.object(reload_scripts, 'affected_host_symbols', side_effect=relevant):
                objects = [one, two]
                game = [one]
                output, reused, reasons = reload_scripts.alias_objects(
                    objects, game, aliases, {'host_func': 10}, {'state': 4})
                self.assertEqual(reused, 0)
                self.assertEqual(len(calls), 2)
                self.assertEqual([p.read_bytes() for p in output],
                                 [b'game generation one', b'unchanged engine'])

                output, reused, reasons = reload_scripts.alias_objects(
                    objects, game, aliases, {'host_func': 10}, {'state': 4})
                self.assertEqual(reused, 2)
                self.assertEqual(len(calls), 2)

                one.write_bytes(b'game generation two')
                _, reused, reasons = reload_scripts.alias_objects(
                    objects, game, aliases, {'host_func': 10}, {'state': 4})
                self.assertEqual(reused, 1)
                self.assertEqual(len(calls), 3)

                _, reused, reasons = reload_scripts.alias_objects(
                    objects, game, aliases, {'host_func': 10, 'new_func': 8},
                    {'state': 4})
                self.assertEqual(reused, 1)
                self.assertEqual(len(calls), 4)

                _, reused, reasons = reload_scripts.alias_objects(
                    objects, game, aliases, {'host_func': 10, 'new_func': 8},
                    {'state': 4, 'more_state': 8})
                self.assertEqual(reused, 1)
                self.assertEqual(len(calls), 5)

                # Adding unrelated host exports must not invalidate any object.
                _, reused, reasons = reload_scripts.alias_objects(
                    objects, game, aliases,
                    {'host_func': 10, 'new_func': 8, 'irrelevant': 1},
                    {'state': 4, 'more_state': 8})
                self.assertEqual(reused, 2)
                self.assertEqual(len(calls), 5)

                output[1].unlink()
                _, reused, reasons = reload_scripts.alias_objects(
                    objects, game, aliases, {'host_func': 10, 'new_func': 8},
                    {'state': 4, 'more_state': 8})
                self.assertEqual(reused, 1)
                self.assertEqual(len(calls), 6)



class BuildActivityTests(unittest.TestCase):
    def test_modified_output_is_not_assumed_to_mean_recompiled(self):
        before = {
            'game': {'game.o': (100, 1)},
            'dependencies': {'engine.o': (100, 1), 'editor.o': (100, 1)},
            'reflection': {'vdata.o': (50, 1)},
        }
        after = {
            'game': {'game.o': (110, 2), 'other.o': (50, 2)},
            'dependencies': {'engine.o': (100, 1), 'editor.o': (100, 1)},
            'reflection': {'vdata.o': (60, 2)},
        }
        result = reload_scripts.build_output_activity(before, after)
        self.assertEqual(result['game'], {'total': 2, 'rewritten': 1, 'new': 1})
        self.assertEqual(result['dependencies'], {'total': 2, 'rewritten': 0, 'new': 0})
        self.assertEqual(result['reflection'], {'total': 1, 'rewritten': 1, 'new': 0})

    def test_linux_inventory_distinguishes_game_from_dependencies(self):
        with tempfile.TemporaryDirectory() as folder:
            workspace = Path(folder)
            game_root = workspace / 'build/Debug_Linux64/Test'
            engine_root = workspace / 'build/Debug_Linux64/Tallow'
            game_root.mkdir(parents=True)
            engine_root.mkdir(parents=True)
            game = game_root / 'script.o'
            engine = engine_root / 'engine.o'
            metadata = game_root / 'vdata.o'
            game.write_bytes(b'one')
            engine.write_bytes(b'two')
            metadata.write_bytes(b'three')
            (game_root / 'ObjectArgs.txt').write_text(str(game) + ' ' + str(engine))
            artifacts = reload_scripts.beef_build_artifacts(workspace, 'Test', 'linux')
            self.assertEqual(artifacts['game'], [game])
            self.assertEqual(artifacts['dependencies'], [engine])
            before = reload_scripts.build_output_state(workspace, 'Test', 'linux')
            engine.write_bytes(b'longer engine contents')
            after = reload_scripts.build_output_state(workspace, 'Test', 'linux')
            activity = reload_scripts.build_output_activity(before, after)
            self.assertEqual(activity['dependencies']['rewritten'], 1)
            self.assertEqual(activity['game']['rewritten'], 0)




class ChangeClassificationTests(unittest.TestCase):
    def test_whitespace_only_edits_do_not_request_recompile(self):
        source = 'class Player { public int speed = 2; void Update() { speed++; } }'
        formatted = 'class Player{\n    public int speed = 2;\n    void Update(){ speed++; }\n}'
        self.assertEqual(reload_scripts.normalized_source(source),
                         reload_scripts.normalized_source(formatted))
        self.assertNotEqual(reload_scripts.normalized_source(source),
                            reload_scripts.normalized_source(formatted.replace('speed++', 'speed += 2')))
        base = {'resident': 'engine', 'schemas': {'Player.bf': 'signature'},
                'code': 'raw1', 'normalized_code': reload_scripts.normalized_source(source)}
        now = {**base, 'code': 'raw2',
               'normalized_code': reload_scripts.normalized_source(formatted)}
        self.assertEqual(reload_scripts.classify_changes(base, now), 0)
        now['normalized_code'] = reload_scripts.normalized_source(formatted.replace('speed++', 'speed += 2'))
        self.assertEqual(reload_scripts.classify_changes(base, now), 10)

    def test_literal_and_preprocessor_whitespace_is_not_ignored(self):
        self.assertNotEqual(reload_scripts.normalized_source('let s = "a b";'),
                            reload_scripts.normalized_source('let s = "a  b";'))
        self.assertNotEqual(reload_scripts.normalized_source('#if A\nfoo();'),
                            reload_scripts.normalized_source('#if A\n foo();'))
        self.assertNotEqual(reload_scripts.normalized_source('let s = """ a b """;'),
                            reload_scripts.normalized_source('let s = """ a  b """;'))

    def test_classify_saved_edits_without_compiling(self):
        baseline = {'resident': 'engine', 'schemas': {'Player.bf': 'signature'}, 'code': 'old'}
        self.assertEqual(reload_scripts.classify_changes(baseline, baseline), 0)
        method = {**baseline, 'code': 'new'}
        self.assertEqual(reload_scripts.classify_changes(baseline, method), 10)
        structural = {**method, 'schemas': {'Player.bf': 'new signature'}}
        self.assertEqual(reload_scripts.classify_changes(baseline, structural), 11)
        incompatible = {**baseline, 'resident': 'updated engine'}
        self.assertEqual(reload_scripts.classify_changes(baseline, incompatible), 3)


class ReloadStrategyTests(unittest.TestCase):
    def test_method_only_edits_use_lightweight_linux_path(self):
        baseline = {'schemas': {'Scripts/Player.bf': 'declaration'}, 'code': 'old'}
        updated = {'schemas': baseline['schemas'], 'code': 'new'}
        self.assertEqual(reload_scripts.reload_strategy('automatic', baseline, updated, 'linux'), 'methods')
        self.assertEqual(reload_scripts.reload_strategy('conservative', baseline, updated, 'linux'), 'structural')
        self.assertEqual(reload_scripts.reload_strategy('automatic', baseline, updated, 'windows'), 'structural')
        self.assertEqual(reload_scripts.reload_strategy('automatic', baseline, baseline, 'linux'), 'structural')

    def test_method_patch_disabled_after_structural_activation(self):
        baseline = {'schemas': {'Scripts/Player.bf': 'declaration'}, 'code': 'old',
                    'method_patch_eligible': False}
        updated = {'schemas': baseline['schemas'], 'code': 'new'}
        self.assertEqual(reload_scripts.reload_strategy('automatic', baseline, updated, 'linux'), 'structural')

    def test_schema_change_detection(self):
        original = 'namespace Demo; class Player { int speed = 1; void Tick() { speed++; } }'
        body_changed = 'namespace Demo; class Player { int speed = 1; void Tick() { speed += 2; } }'
        field_changed = 'namespace Demo; class Player { int speed = 2; void Tick() { speed++; } }'
        self.assertEqual(reload_scripts.schema(original), reload_scripts.schema(body_changed))
        self.assertNotEqual(reload_scripts.schema(original), reload_scripts.schema(field_changed))

    def test_declaration_changes_use_structural_path(self):
        baseline = {'schemas': {'Scripts/Player.bf': 'old'}, 'code': 'old'}
        updated = {'schemas': {'Scripts/Player.bf': 'new'}, 'code': 'new'}
        self.assertEqual(reload_scripts.reload_strategy('automatic', baseline, updated, 'linux'), 'structural')
        added = {'schemas': {**baseline['schemas'], 'Scripts/Enemy.bf': 'new'}, 'code': 'new'}
        self.assertEqual(reload_scripts.reload_strategy('automatic', baseline, added, 'linux'), 'structural')


if __name__ == '__main__':
    unittest.main()
