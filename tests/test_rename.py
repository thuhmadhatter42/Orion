"""The one renamer (app_run.renamed_name / rename_file) and the one recogniser (app_run.is_tagged),
and the `rename` subcommand the app calls after the user says yes (J 2026-11-18, idea 2)."""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import app_run  # noqa: E402


class TestRecogniser(unittest.TestCase):
    def test_its_own_tag_is_recognised_for_every_key_count(self):
        for keys in ([("Cm", 1)], [("Cm", 1), ("Eb", 1)], [("Cm", 1), ("Eb", 1), ("Gm", 1)]):
            name = app_run.renamed_name("Beat", "wav", "142.0", keys)
            self.assertTrue(app_run.is_tagged(name), name)

    def test_flats_and_sharps_and_decimals(self):
        for n in ("a (77.0 BPM D# D#m G#).mp3", "a (128 BPM Bbm Db F#m).wav", "a (140.82 BPM Ab).aif"):
            self.assertTrue(app_run.is_tagged(n), n)

    def test_a_producers_own_bpm_or_key_does_not_count(self):
        for n in ("Beat 140 BPM Cm.wav", "Beat (140 BPM).wav", "Beat (Cm).wav", "Beat - 140bpm - Cm.mp3",
                  "Beat (140 BPM Cm and more).wav", "Beat.wav", "Beat (BPM Cm).wav"):
            self.assertFalse(app_run.is_tagged(n), n)

    def test_the_tag_must_end_the_name(self):
        self.assertFalse(app_run.is_tagged("Beat (142.0 BPM Cm Eb Gm) copy.wav"))
        self.assertFalse(app_run.is_tagged("Beat (142.0 BPM Cm Eb Gm Am Bm).wav"))   # more than the tag ever holds

    def test_a_full_path(self):
        self.assertTrue(app_run.is_tagged("/x/y/Beat (90.0 BPM Am).wav"))
        self.assertFalse(app_run.is_tagged("/x/y (90.0 BPM Am)/Beat.wav"))   # only the file's own name counts

    def test_tags_written_with_other_key_counts_stay_recognised(self):
        with mock.patch.object(app_run, "KEY_COUNT", 1):
            name = app_run.renamed_name("Beat", "wav", "90.0", [("Am", 1), ("C", 1)])
        self.assertEqual(name, "Beat (90.0 BPM Am).wav")
        self.assertTrue(app_run.is_tagged(name))
        self.assertTrue(app_run.is_tagged("Beat (90.0 BPM Am C Em).wav"))


class TestFormat(unittest.TestCase):
    def test_format_is_the_original_apps(self):
        self.assertEqual(app_run.renamed_name("T", "mp3", "142.0", [("Cm", 73), ("Eb", 18), ("Gm", 9)]),
                         "T (142.0 BPM Cm Eb Gm).mp3")

    def test_key_count_is_one_constant(self):
        self.assertEqual(app_run.KEY_COUNT, 3)
        keys = [("Cm", 1), ("Eb", 1), ("Gm", 1), ("Am", 1)]
        self.assertEqual(app_run.renamed_name("T", "mp3", "90", keys), "T (90 BPM Cm Eb Gm).mp3")
        with mock.patch.object(app_run, "KEY_COUNT", 1):
            self.assertEqual(app_run.renamed_name("T", "mp3", "90", keys), "T (90 BPM Cm).mp3")

    def test_no_extension_keeps_none(self):
        self.assertEqual(app_run.renamed_name("T", "", "90", [("Cm", 1)]), "T (90 BPM Cm)")


class Base(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory()
        self.dir = Path(self._t.name)

    def tearDown(self):
        self._t.cleanup()

    def make(self, name, data=b"x"):
        p = self.dir / name
        p.write_bytes(data)
        return p

    def run_cmd(self, fn, *args):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
            fn(*args)
        return [json.loads(l) for l in buf.getvalue().splitlines() if l.strip()]


class TestRenameFile(Base):
    def test_renames_in_place_keeping_contents_and_folder(self):
        p = self.make("Beat.wav", b"audio")
        new = app_run.rename_file(p, "142.0", [("Cm", 0), ("Eb", 0), ("Gm", 0)])
        self.assertEqual(new, self.dir / "Beat (142.0 BPM Cm Eb Gm).wav")
        self.assertFalse(p.exists())
        self.assertEqual(new.read_bytes(), b"audio")

    def test_never_overwrites_another_file(self):
        p = self.make("Beat.wav", b"mine")
        other = self.make("Beat (142.0 BPM Cm).wav", b"theirs")
        with self.assertRaises(FileExistsError):
            app_run.rename_file(p, "142.0", [("Cm", 0)])
        self.assertEqual(other.read_bytes(), b"theirs")
        self.assertEqual(p.read_bytes(), b"mine")

    def test_no_usable_bpm_or_no_key_is_refused(self):
        p = self.make("Beat.wav", b"mine")
        for bpm, keys in (("0.0", [("Cm", 0)]), ("0", [("Cm", 0)]), ("", [("Cm", 0)]), (None, [("Cm", 0)]),
                          ("nan", [("Cm", 0)]), ("142.0", [])):
            with self.assertRaises(ValueError, msg=repr((bpm, keys))):
                app_run.rename_file(p, bpm, keys)
            with self.assertRaises(ValueError):
                app_run.rename_file(p, bpm, keys, overwrite=True)
        self.assertEqual(p.read_bytes(), b"mine")
        self.assertEqual([f.name for f in self.dir.iterdir()], ["Beat.wav"])

    def test_the_download_path_may_overwrite(self):
        p = self.make("Beat.mp3", b"new")
        self.make("Beat (142.0 BPM Cm).mp3", b"old")
        new = app_run.rename_file(p, "142.0", [("Cm", 0)], overwrite=True)
        self.assertEqual(new.read_bytes(), b"new")


class TestRenameCommand(Base):
    def test_renamed_event_carries_both_paths(self):
        p = self.make("Beat.wav")
        ev = self.run_cmd(app_run.cmd_rename, str(p), "142.0", ["Cm", "Eb", "Gm"])
        self.assertEqual(len(ev), 1, ev)
        self.assertEqual(ev[0]["stage"], "renamed")
        self.assertEqual(ev[0]["file"], str(p))
        self.assertEqual(ev[0]["to"], str(self.dir / "Beat (142.0 BPM Cm Eb Gm).wav"))
        self.assertEqual(ev[0]["name"], "Beat (142.0 BPM Cm Eb Gm).wav")
        self.assertTrue((self.dir / ev[0]["name"]).is_file())

    def test_an_already_tagged_file_is_skipped_not_renamed_again(self):
        p = self.make("Beat (142.0 BPM Cm Eb Gm).wav")
        ev = self.run_cmd(app_run.cmd_rename, str(p), "150.0", ["Am"])
        self.assertEqual([e["stage"] for e in ev], ["rename_skipped"])
        self.assertEqual(ev[0]["reason"], "tagged")
        self.assertTrue(p.is_file())

    def test_a_missing_file_fails_with_errno(self):
        ev = self.run_cmd(app_run.cmd_rename, str(self.dir / "nope.wav"), "142.0", ["Cm"])
        self.assertEqual([e["stage"] for e in ev], ["rename_failed"])
        self.assertEqual(ev[0]["errno"], 2)   # ENOENT
        self.assertTrue(ev[0]["message"])

    def test_a_taken_name_fails_with_eexist_and_changes_nothing(self):
        p = self.make("Beat.wav", b"mine")
        self.make("Beat (142.0 BPM Cm).wav", b"theirs")
        ev = self.run_cmd(app_run.cmd_rename, str(p), "142.0", ["Cm"])
        self.assertEqual([e["stage"] for e in ev], ["rename_failed"])
        self.assertEqual(ev[0]["errno"], 17)  # EEXIST
        self.assertEqual(p.read_bytes(), b"mine")

    def test_a_refused_rename_reports_the_os_errno(self):
        p = self.make("Beat.wav")
        with mock.patch.object(app_run.os, "rename", side_effect=PermissionError(1, "Operation not permitted")):
            ev = self.run_cmd(app_run.cmd_rename, str(p), "142.0", ["Cm"])
        self.assertEqual([e["stage"] for e in ev], ["rename_failed"])
        self.assertEqual(ev[0]["errno"], 1)
        self.assertTrue(p.is_file())

    def test_a_zero_bpm_is_refused_and_reported(self):
        p = self.make("Beat.wav", b"mine")
        ev = self.run_cmd(app_run.cmd_rename, str(p), "0.0", ["Cm"])
        self.assertEqual([e["stage"] for e in ev], ["rename_failed"])
        self.assertIn("not a BPM", ev[0]["message"])
        self.assertEqual(p.read_bytes(), b"mine")

    def test_the_unicode_name_survives(self):
        p = self.make("Béat ✦.wav")
        ev = self.run_cmd(app_run.cmd_rename, str(p), "90.0", ["Am"])
        self.assertEqual(ev[0]["name"], "Béat ✦ (90.0 BPM Am).wav")

    def test_cli_dispatch(self):
        p = self.make("Beat.wav")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            app_run.main(["app_run.py", "rename", str(p), "142.0", "Cm", "Eb", "Gm"])
        ev = [json.loads(l) for l in buf.getvalue().splitlines() if l.strip()]
        self.assertEqual(ev[0]["stage"], "renamed")

    def test_cli_with_too_few_arguments_is_a_usage_error_event(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            app_run.main(["app_run.py", "rename", "only-a-file"])
        ev = [json.loads(l) for l in buf.getvalue().splitlines() if l.strip()]
        self.assertEqual(ev[0]["stage"], "error")


class TestAnalyzeReportsTheTag(Base):
    def test_analyzed_event_says_whether_the_name_is_already_tagged(self):
        tagged = self.make("Beat (142.0 BPM Cm Eb Gm).wav")
        plain = self.make("Beat.wav")
        with mock.patch.object(app_run, "analyze_file", return_value=("142.0", [("Cm", 70)])):
            ev = self.run_cmd(app_run.cmd_analyze, [str(tagged), str(plain)])
        self.assertEqual([e["tagged"] for e in ev if e["stage"] == "analyzed"], [True, False])


if __name__ == "__main__":
    unittest.main()
