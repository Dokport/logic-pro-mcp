#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

import logic_bounce


def _window_metrics_logic_process(body: str, timeout_sec=logic_bounce.OSA_TIMEOUT_SEC):
    if "position of front window" in body:
        return "100, 200"
    if "size of front window" in body:
        return "800, 600"
    return ""


def _ui_events_with_staged_artifact(staging_dir: str, typed_name):
    def fake_ui_events(*commands):
        for command in commands:
            if command.startswith("t:"):
                typed_name["value"] = command[2:]
        if "c:840,768" in commands and typed_name["value"] is not None:
            artifact = os.path.join(staging_dir, f"{typed_name['value']}.aif")
            with open(artifact, "wb") as handle:
                handle.write(b"bounce")
            os.utime(artifact, (1001.0, 1001.0))
        return True

    return fake_ui_events


class LogicBounceMainTests(unittest.TestCase):
    def _run_artifact_recovery(self, *, wrong_directory=False, delay=0, ambiguous=False, temporary=False):
        with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as output_dir:
            staging = os.path.join(home, "Downloads")
            documents = os.path.join(home, "Documents")
            os.mkdir(staging)
            os.mkdir(documents)
            staged_name = "Song--lpmcp-fixed"
            clock = {"now": 1000.0, "fired": None, "created": False}
            source_paths = []
            temporary_path = os.path.join(staging, staged_name + ".tmp")

            def produce_if_ready():
                if clock["fired"] is None or delay is None or clock["created"]:
                    return
                if clock["now"] - clock["fired"] < delay:
                    return
                clock["created"] = True
                if temporary and os.path.exists(temporary_path):
                    os.unlink(temporary_path)
                destinations = [documents if wrong_directory else staging]
                if ambiguous:
                    destinations = [staging, documents]
                for directory in destinations:
                    path = os.path.join(directory, staged_name + ".aif")
                    with open(path, "wb") as artifact:
                        artifact.write(b"bounce")
                    os.utime(path, (clock["now"], clock["now"]))
                    source_paths.append(path)

            def send(*commands):
                if "c:840,768" in commands:
                    clock["fired"] = clock["now"]
                    if temporary:
                        with open(temporary_path, "wb") as artifact:
                            artifact.write(b"unfinished render")
                        os.utime(temporary_path, (clock["now"], clock["now"]))
                    produce_if_ready()
                return True

            def sleep(seconds):
                clock["now"] += seconds
                produce_if_ready()

            def expanduser(path):
                return home if path == "~" else os.path.join(home, path.removeprefix("~/"))

            stdout = io.StringIO()
            with (
                mock.patch.object(sys, "argv", ["logic_bounce.py", "--target-path", os.path.join(output_dir, "Song.wav"), "--staging", staging]),
                mock.patch.object(logic_bounce, "set_input_abc", return_value=True),
                mock.patch.object(logic_bounce, "open_bounce_dialog", return_value=(True, ["key_command"])),
                mock.patch.object(logic_bounce, "click_bounce_settings_confirm", return_value=True),
                mock.patch.object(logic_bounce, "save_panel_present", return_value=True),
                mock.patch.object(logic_bounce, "logic_process_osa", side_effect=_window_metrics_logic_process),
                mock.patch.object(logic_bounce, "send_ui_events", side_effect=send),
                mock.patch.object(logic_bounce, "unique_staging_name", return_value=staged_name),
                mock.patch.object(logic_bounce.os.path, "expanduser", side_effect=expanduser),
                mock.patch.object(logic_bounce.time, "sleep", side_effect=sleep),
                mock.patch.object(logic_bounce.time, "time", side_effect=lambda: clock["now"]),
                mock.patch.object(logic_bounce.time, "monotonic", side_effect=lambda: clock["now"]),
                contextlib.redirect_stdout(stdout),
            ):
                exit_code = logic_bounce.main()
            result = json.loads(stdout.getvalue().strip())
            final = os.path.join(output_dir, "Song.aif")
            final_bytes = None
            if os.path.isfile(final):
                with open(final, "rb") as artifact:
                    final_bytes = artifact.read()
            return exit_code, result, {
                "final_exists": os.path.isfile(final),
                "final_bytes": final_bytes,
                "sources_remaining": sum(os.path.exists(path) for path in source_paths),
                "elapsed": clock["now"] - 1000.0,
                "staging": staging,
                "documents": os.path.realpath(documents),
                "temporary_remaining": os.path.isfile(temporary_path),
                "temporary_output_exists": os.path.exists(os.path.join(output_dir, "Song.tmp")),
            }

    def test_main_recovers_its_fresh_artifact_when_sidebar_lands_in_documents(self):
        code, result, observed = self._run_artifact_recovery(wrong_directory=True)
        self.assertEqual(code, 0, result)
        self.assertTrue(result["bounce_fired"])
        self.assertEqual(result.get("staging_directory"), observed["documents"])
        self.assertEqual(observed["final_bytes"], b"bounce")
        self.assertEqual(observed["sources_remaining"], 0)

    def test_main_waits_for_a_fifty_second_bounce(self):
        code, result, observed = self._run_artifact_recovery(delay=50)
        self.assertEqual(code, 0, result)
        self.assertEqual(observed["final_bytes"], b"bounce")
        self.assertGreaterEqual(observed["elapsed"], 50)
        self.assertLess(observed["elapsed"], 281)

    def test_main_leaves_in_flight_temporary_file_until_final_audio_appears(self):
        code, result, observed = self._run_artifact_recovery(temporary=True, delay=50)
        self.assertEqual(code, 0, result)
        self.assertEqual(observed["final_bytes"], b"bounce")
        self.assertFalse(observed["temporary_output_exists"])
        self.assertGreaterEqual(observed["elapsed"], 50)

    def test_main_never_moves_or_reports_an_unfinished_temporary_render(self):
        code, result, observed = self._run_artifact_recovery(temporary=True, delay=None)
        self.assertEqual(code, 1, result)
        self.assertTrue(result["bounce_fired"])
        self.assertTrue(observed["temporary_remaining"])
        self.assertFalse(observed["temporary_output_exists"])
        self.assertFalse(observed["final_exists"])

    def test_main_refuses_two_distinct_fresh_artifacts_without_moving_either(self):
        code, result, observed = self._run_artifact_recovery(ambiguous=True)
        self.assertEqual(code, 1, result)
        self.assertEqual(result.get("error"), "ambiguous_bounce_artifacts")
        self.assertFalse(observed["final_exists"])
        self.assertEqual(observed["sources_remaining"], 2)

    def test_main_exhausts_one_bounded_helper_budget_without_an_artifact(self):
        code, result, observed = self._run_artifact_recovery(delay=None)
        self.assertEqual(code, 1, result)
        self.assertTrue(result["bounce_fired"])
        self.assertFalse(observed["final_exists"])
        self.assertGreaterEqual(observed["elapsed"], 250)
        self.assertLess(observed["elapsed"], 281)

    def test_main_fails_closed_when_save_panel_is_not_detected(self):
        with tempfile.TemporaryDirectory() as staging_dir, tempfile.TemporaryDirectory() as output_dir:
            argv = [
                "logic_bounce.py",
                "--target-path", os.path.join(output_dir, "Song.wav"),
                "--staging", staging_dir,
            ]
            stdout = io.StringIO()
            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(logic_bounce, "set_input_abc", return_value=True),
                mock.patch.object(logic_bounce, "open_bounce_dialog", return_value=(True, ["key_command"])),
                mock.patch.object(logic_bounce, "click_bounce_settings_confirm", return_value=True),
                mock.patch.object(logic_bounce, "bounce_dialog_present", return_value=False),
                mock.patch.object(logic_bounce, "bounce_focus_diagnostics", return_value={"frontmost_app": "Logic Pro"}),
                mock.patch.object(logic_bounce, "save_panel_present", return_value=False),
                mock.patch.object(logic_bounce, "logic_process_osa", side_effect=_window_metrics_logic_process),
                mock.patch.object(logic_bounce, "send_ui_events", return_value=None),
                mock.patch.object(logic_bounce.time, "sleep", lambda _: None),
                mock.patch.object(logic_bounce.time, "time", lambda: 1000.0),
                mock.patch.object(logic_bounce.os.path, "expanduser", return_value=staging_dir),
                contextlib.redirect_stdout(stdout),
            ):
                exit_code = logic_bounce.main()

            result = json.loads(stdout.getvalue().strip())
            self.assertEqual(exit_code, 1, result)
            self.assertEqual(result["error"], "bounce_save_panel_did_not_appear")
            self.assertFalse(result["save_panel_present"])

    def test_main_accepts_save_panel_even_when_window_title_still_contains_bounce(self):
        with tempfile.TemporaryDirectory() as staging_dir, tempfile.TemporaryDirectory() as output_dir:
            typed_name = {"value": None}
            staged_name = "Song--lpmcp-fixed"
            argv = [
                "logic_bounce.py",
                "--target-path", os.path.join(output_dir, "Song.wav"),
                "--staging", staging_dir,
            ]
            stdout = io.StringIO()
            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(logic_bounce, "set_input_abc", return_value=True),
                mock.patch.object(logic_bounce, "open_bounce_dialog", return_value=(True, ["key_command"])),
                mock.patch.object(logic_bounce, "click_bounce_settings_confirm", return_value=True),
                mock.patch.object(logic_bounce, "bounce_dialog_present", return_value=True),
                mock.patch.object(logic_bounce, "save_panel_present", return_value=True),
                mock.patch.object(logic_bounce, "logic_process_osa", side_effect=_window_metrics_logic_process),
                mock.patch.object(logic_bounce, "send_ui_events", side_effect=_ui_events_with_staged_artifact(staging_dir, typed_name)),
                mock.patch.object(logic_bounce.time, "sleep", lambda _: None),
                mock.patch.object(logic_bounce.time, "time", lambda: 1000.0),
                mock.patch.object(logic_bounce.os.path, "expanduser", return_value=staging_dir),
                mock.patch.object(logic_bounce, "unique_staging_name", return_value=staged_name),
                contextlib.redirect_stdout(stdout),
            ):
                exit_code = logic_bounce.main()

            result = stdout.getvalue().strip()
            self.assertEqual(exit_code, 0, result)
            self.assertEqual(typed_name["value"], staged_name)
            self.assertTrue(os.path.exists(os.path.join(output_dir, "Song.aif")))

    def test_main_types_unique_staging_name_before_polling_staging(self):
        with tempfile.TemporaryDirectory() as staging_dir, tempfile.TemporaryDirectory() as output_dir:
            typed_name = {"value": None}
            staged_name = "Song--lpmcp-fixed"
            argv = [
                "logic_bounce.py",
                "--target-path", os.path.join(output_dir, "Song.wav"),
                "--staging", staging_dir,
            ]
            stdout = io.StringIO()
            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(logic_bounce, "set_input_abc", return_value=True),
                mock.patch.object(logic_bounce, "open_bounce_dialog", return_value=(True, ["key_command"])),
                mock.patch.object(logic_bounce, "click_bounce_settings_confirm", return_value=True),
                mock.patch.object(logic_bounce, "bounce_dialog_present", return_value=False),
                mock.patch.object(logic_bounce, "save_panel_present", return_value=True),
                mock.patch.object(logic_bounce, "logic_process_osa", side_effect=_window_metrics_logic_process),
                mock.patch.object(logic_bounce, "send_ui_events", side_effect=_ui_events_with_staged_artifact(staging_dir, typed_name)),
                mock.patch.object(logic_bounce.time, "sleep", lambda _: None),
                mock.patch.object(logic_bounce.time, "time", lambda: 1000.0),
                mock.patch.object(logic_bounce.os.path, "expanduser", return_value=staging_dir),
                mock.patch.object(logic_bounce, "unique_staging_name", return_value=staged_name),
                contextlib.redirect_stdout(stdout),
            ):
                exit_code = logic_bounce.main()

            result = stdout.getvalue().strip()
            self.assertEqual(exit_code, 0, result)
            self.assertEqual(typed_name["value"], staged_name)
            self.assertTrue(os.path.exists(os.path.join(output_dir, "Song.aif")))

    def test_main_keeps_bounce_fired_false_when_final_bounce_click_fails(self):
        with tempfile.TemporaryDirectory() as staging_dir, tempfile.TemporaryDirectory() as output_dir:
            argv = [
                "logic_bounce.py",
                "--target-path", os.path.join(output_dir, "Song.wav"),
                "--staging", staging_dir,
            ]
            stdout = io.StringIO()

            def fake_ui_events(*commands):
                return "c:840,768" not in commands

            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(logic_bounce, "set_input_abc", return_value=True),
                mock.patch.object(logic_bounce, "open_bounce_dialog", return_value=(True, ["key_command"])),
                mock.patch.object(logic_bounce, "click_bounce_settings_confirm", return_value=True),
                mock.patch.object(logic_bounce, "save_panel_present", return_value=True),
                mock.patch.object(logic_bounce, "logic_process_osa", side_effect=_window_metrics_logic_process),
                mock.patch.object(logic_bounce, "send_ui_events", side_effect=fake_ui_events),
                mock.patch.object(logic_bounce.time, "sleep", lambda _: None),
                mock.patch.object(logic_bounce.time, "time", lambda: 1000.0),
                mock.patch.object(logic_bounce.os.path, "expanduser", return_value=staging_dir),
                mock.patch.object(logic_bounce, "unique_staging_name", return_value="Song--lpmcp-fixed"),
                contextlib.redirect_stdout(stdout),
            ):
                exit_code = logic_bounce.main()

            result = json.loads(stdout.getvalue().strip())
            self.assertEqual(exit_code, 1, result)
            self.assertFalse(result["bounce_fired"], result)
            self.assertEqual(result["error"], "bounce_button_click_failed")
