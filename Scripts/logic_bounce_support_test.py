#!/usr/bin/env python3
from __future__ import annotations

import os
import json
import subprocess
import tempfile
import time
import unittest
from unittest import mock

import logic_bounce
import logic_bounce_ui
from logic_bounce import TARGET_INPUT_SOURCE_IDS, _select_input_source, set_input_abc


class FakeTISRuntime:
    def __init__(self, sources, source_ids, select_results=None):
        self._sources = list(sources)
        self._source_ids = dict(source_ids)
        self._select_results = dict(select_results or {})
        self.selected_ids = []

    def available_source_ids(self):
        return [self._source_ids[source] for source in self._sources if source in self._source_ids]

    def select_source_id(self, source_id):
        self.selected_ids.append(source_id)
        return self._select_results.get(source_id, True)


class LogicBounceSupportTests(unittest.TestCase):
    def test_render_project_identity_requires_a_readable_unobstructed_saved_project(self):
        baseline = {"status": "ok", "process_id": 123, "role": "AXWindow", "subrole": "AXStandardWindow", "document": "file:///Fixture.logicx/", "sheet_count": 0}
        def run(payload):
            return lambda _: subprocess.CompletedProcess([], 0, json.dumps(payload), "")
        self.assertEqual(logic_bounce_ui.bounce_project_identity(run(baseline)), (123, "file:///Fixture.logicx/"))
        for change in ({"status": "error"}, {"subrole": "AXDialog"}, {"sheet_count": 1}, {"sheet_count": False}, {"process_id": True}, {"document": ""}, {"document": "https://example.test/"}, {"role": ""}):
            with self.subTest(change=change):
                self.assertIsNone(logic_bounce_ui.bounce_project_identity(run({**baseline, **change})))

    def test_render_project_identity_does_not_convert_probe_failures_to_completion(self):
        for result in (subprocess.CompletedProcess([], 1, '{}', 'denied'), subprocess.CompletedProcess([], 0, 'not JSON', '')):
            with self.subTest(result=result):
                self.assertIsNone(logic_bounce_ui.bounce_project_identity(lambda _: result))
        def timeout(_):
            raise subprocess.TimeoutExpired("probe", 12)
        self.assertIsNone(logic_bounce_ui.bounce_project_identity(timeout))

    def test_find_staged_artifact_never_selects_an_empty_audio_file(self):
        with tempfile.TemporaryDirectory() as staging_dir:
            path = os.path.join(staging_dir, "bounce--lpmcp-fixed.aif")
            with open(path, "wb"):
                pass
            self.assertIsNone(logic_bounce.find_staged_artifact(staging_dir, "bounce--lpmcp-fixed", time.time() - 1))

    def test_artifact_locations_preserve_the_bounded_standard_filesystem_paths(self):
        with tempfile.TemporaryDirectory() as home:
            def expanduser(path):
                return home if path == "~" else os.path.join(home, path.removeprefix("~/"))
            with mock.patch.object(logic_bounce.os.path, "expanduser", side_effect=expanduser):
                actual = logic_bounce.bounce_artifact_locations(os.path.join(home, "Downloads"), os.path.join(home, "out"))
            expected = ["Downloads", "Documents", "Desktop", "Music", "Movies", "", "out"]
            self.assertEqual(actual, [os.path.realpath(os.path.join(home, path)) for path in expected])

    def test_select_input_source_prefers_abc_before_us_fallback(self):
        runtime = FakeTISRuntime(
            sources=[1, 2],
            source_ids={1: TARGET_INPUT_SOURCE_IDS[1], 2: TARGET_INPUT_SOURCE_IDS[0]},
        )
        self.assertTrue(_select_input_source(runtime))
        self.assertEqual(runtime.selected_ids, [TARGET_INPUT_SOURCE_IDS[0]])

    def test_select_input_source_falls_back_to_us_when_abc_missing(self):
        runtime = FakeTISRuntime(sources=[1], source_ids={1: TARGET_INPUT_SOURCE_IDS[1]})
        self.assertTrue(_select_input_source(runtime))
        self.assertEqual(runtime.selected_ids, [TARGET_INPUT_SOURCE_IDS[1]])

    def test_select_input_source_falls_back_to_us_when_abc_select_fails(self):
        runtime = FakeTISRuntime(
            sources=[1, 2],
            source_ids={1: TARGET_INPUT_SOURCE_IDS[0], 2: TARGET_INPUT_SOURCE_IDS[1]},
            select_results={TARGET_INPUT_SOURCE_IDS[0]: False, TARGET_INPUT_SOURCE_IDS[1]: True},
        )
        self.assertTrue(_select_input_source(runtime))
        self.assertEqual(runtime.selected_ids, list(TARGET_INPUT_SOURCE_IDS))

    def test_select_input_source_returns_false_when_matching_layout_missing(self):
        runtime = FakeTISRuntime(sources=[1], source_ids={1: "com.example.layout.Korean"})
        self.assertFalse(_select_input_source(runtime))
        self.assertEqual(runtime.selected_ids, [])

    def test_select_input_source_returns_false_when_runtime_cannot_list_sources(self):
        class EmptyRuntime:
            def available_source_ids(self):
                return None

        self.assertFalse(_select_input_source(EmptyRuntime()))

    def test_set_input_abc_returns_false_when_runtime_unavailable(self):
        with mock.patch.object(logic_bounce.TISRuntime, "load", return_value=None):
            self.assertFalse(set_input_abc())

    def test_set_input_abc_returns_false_when_selection_fails(self):
        runtime = FakeTISRuntime(
            sources=[1],
            source_ids={1: TARGET_INPUT_SOURCE_IDS[0]},
            select_results={TARGET_INPUT_SOURCE_IDS[0]: False},
        )
        self.assertFalse(set_input_abc(runtime=runtime))
        self.assertEqual(runtime.selected_ids, [TARGET_INPUT_SOURCE_IDS[0]])

    def test_find_staged_artifact_accepts_fresh_regular_file_under_staging(self):
        with tempfile.TemporaryDirectory() as staging_dir:
            staged_name = "bounce--lpmcp-1234"
            artifact = os.path.join(staging_dir, f"{staged_name}.wav")
            with open(artifact, "wb") as handle:
                handle.write(b"fresh")
            run_started_at = time.time() - 1.0

            self.assertEqual(
                logic_bounce.find_staged_artifact(staging_dir, staged_name, run_started_at),
                artifact,
            )

    def test_find_staged_artifact_matches_literal_filename_metacharacters(self):
        with tempfile.TemporaryDirectory() as staging_dir:
            staged_name = "Song [alternate]*?--lpmcp-fixed"
            artifact = os.path.join(staging_dir, staged_name + ".aif")
            with open(artifact, "wb") as handle:
                handle.write(b"literal")
            self.assertEqual(
                logic_bounce.find_staged_artifact(staging_dir, staged_name, time.time() - 1),
                artifact,
            )

    def test_find_staged_artifact_ignores_temporary_and_unrecognized_suffixes(self):
        with tempfile.TemporaryDirectory() as staging_dir:
            staged_name = "bounce--lpmcp-fixed"
            for suffix in ("tmp", "aif.tmp", "part", "txt"):
                with self.subTest(suffix=suffix):
                    path = os.path.join(staging_dir, staged_name + "." + suffix)
                    with open(path, "wb") as artifact:
                        artifact.write(b"unfinished render")
                    self.assertIsNone(logic_bounce.find_staged_artifact(
                        staging_dir, staged_name, time.time() - 1,
                    ))
                    os.unlink(path)

    def test_find_staged_artifact_rejects_stale_same_basename_candidate(self):
        with tempfile.TemporaryDirectory() as staging_dir:
            staged_name = "bounce--lpmcp-1234"
            artifact = os.path.join(staging_dir, f"{staged_name}.wav")
            with open(artifact, "wb") as handle:
                handle.write(b"stale")
            run_started_at = time.time()
            stale_mtime = run_started_at - 60.0
            os.utime(artifact, (stale_mtime, stale_mtime))

            self.assertIsNone(logic_bounce.find_staged_artifact(staging_dir, staged_name, run_started_at))

    def test_find_staged_artifact_rejects_symlinked_candidate(self):
        with tempfile.TemporaryDirectory() as staging_dir, tempfile.TemporaryDirectory() as outside_dir:
            staged_name = "bounce--lpmcp-1234"
            outside_artifact = os.path.join(outside_dir, f"{staged_name}.wav")
            with open(outside_artifact, "wb") as handle:
                handle.write(b"outside")
            link_path = os.path.join(staging_dir, f"{staged_name}.wav")
            os.symlink(outside_artifact, link_path)
            run_started_at = time.time() - 1.0

            self.assertIsNone(logic_bounce.find_staged_artifact(staging_dir, staged_name, run_started_at))

    def test_move_staged_artifact_no_overwrite_rejects_existing_target(self):
        with tempfile.TemporaryDirectory() as work_dir:
            staged = os.path.join(work_dir, "Song--lpmcp-1234.aif")
            final = os.path.join(work_dir, "Song.aif")
            with open(staged, "wb") as handle:
                handle.write(b"new")
            with open(final, "wb") as handle:
                handle.write(b"old")

            self.assertEqual(
                logic_bounce.move_staged_artifact_no_overwrite(staged, final),
                "artifact_already_exists",
            )
            self.assertTrue(os.path.exists(staged))
            with open(final, "rb") as handle:
                self.assertEqual(handle.read(), b"old")

    def test_move_staged_artifact_no_overwrite_rejects_symlinked_output_directory(self):
        with tempfile.TemporaryDirectory() as work_dir, tempfile.TemporaryDirectory() as outside_dir:
            staged = os.path.join(work_dir, "Song--lpmcp-1234.aif")
            trusted_root = os.path.join(work_dir, "exports")
            final = os.path.join(trusted_root, "Song.aif")
            outside_final = os.path.join(outside_dir, "Song.aif")
            with open(staged, "wb") as handle:
                handle.write(b"new")
            os.mkdir(trusted_root)
            os.rmdir(trusted_root)
            os.symlink(outside_dir, trusted_root)

            self.assertEqual(
                logic_bounce.move_staged_artifact_no_overwrite(staged, final),
                "artifact_output_dir_unsafe",
            )
            self.assertTrue(os.path.exists(staged))
            self.assertFalse(os.path.exists(outside_final))

    def test_move_staged_artifact_no_overwrite_cleans_up_via_pinned_directory_fd(self):
        with tempfile.TemporaryDirectory() as work_dir, tempfile.TemporaryDirectory() as outside_dir:
            staged = os.path.join(work_dir, "Song--lpmcp-1234.aif")
            trusted_root = os.path.join(work_dir, "exports")
            moved_root = os.path.join(work_dir, "exports-moved")
            final = os.path.join(trusted_root, "Song.aif")
            escaped_final = os.path.join(outside_dir, "Song.aif")
            with open(staged, "wb") as handle:
                handle.write(b"new")
            os.mkdir(trusted_root)
            with open(escaped_final, "wb") as handle:
                handle.write(b"sentinel")

            def swap_root_then_fail(source, destination):
                del source, destination
                os.rename(trusted_root, moved_root)
                os.symlink(outside_dir, trusted_root)
                raise OSError("copy failed")

            with mock.patch.object(logic_bounce.shutil, "copyfileobj", side_effect=swap_root_then_fail):
                self.assertEqual(
                    logic_bounce.move_staged_artifact_no_overwrite(staged, final),
                    "artifact_move_failed: copy failed",
                )

            self.assertTrue(os.path.exists(staged))
            with open(escaped_final, "rb") as handle:
                self.assertEqual(handle.read(), b"sentinel")
