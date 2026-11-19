"""A damaged analyzer says so: no backup tempo method. bpm.py in file mode refuses (exit 2, one line
on stderr naming Doctor, nothing on stdout) when essentia or its tempo model is missing. (The app no
longer runs bpm.py: its analyzer is the core, whose refusal CoreFileTests / LiveTests cover.)
Run with the bundled Python: bin/python/bin/python3 -m unittest discover -s tests"""
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
WAV = ROOT / "tests" / "fixtures" / "click120.wav"

MESSAGE = "The analyzer is incomplete. Run Doctor."

# bpm.py's file mode with both tempo model paths pointed at a file that does not exist
_NO_MODEL = (
    "import sys; sys.path.insert(0, {root!r}); import bpm; "
    "bpm.TEMPOCNN_MODEL = bpm.TEMPOCNN_WEIGHTS = bpm.HERE / 'models' / 'no-such-model'; "
    "sys.argv = ['bpm.py', {wav!r}]; bpm.main()"
)
_NO_ESSENTIA = (
    "import sys; sys.path.insert(0, {root!r}); import bpm; "
    "bpm._have_essentia = lambda: False; "
    "sys.argv = ['bpm.py', {wav!r}]; bpm.main()"
)

# bpm.py --check, the same two damages
_CHECK_NO_MODEL = _NO_MODEL.replace("sys.argv = ['bpm.py', {wav!r}]", "sys.argv = ['bpm.py', '--check']")
_CHECK_NO_ESSENTIA = _NO_ESSENTIA.replace("sys.argv = ['bpm.py', {wav!r}]", "sys.argv = ['bpm.py', '--check']")


def run_bpm(template):
    code = template.format(root=str(ROOT), wav=str(WAV))
    return subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=120)


class TestBpmRefuses(unittest.TestCase):
    def test_missing_model_exits_nonzero_names_doctor_prints_no_bpm(self):
        p = run_bpm(_NO_MODEL)
        self.assertNotEqual(p.returncode, 0, (p.stdout, p.stderr))
        self.assertEqual(p.stdout, "", "no BPM line, from any method")
        self.assertEqual(p.stderr.strip(), MESSAGE)

    def test_no_essentia_exits_nonzero_names_doctor_prints_no_bpm(self):
        p = run_bpm(_NO_ESSENTIA)
        self.assertNotEqual(p.returncode, 0, (p.stdout, p.stderr))
        self.assertEqual(p.stdout, "")
        self.assertEqual(p.stderr.strip(), MESSAGE)

    def test_the_analyzer_has_no_second_method(self):
        text = (ROOT / "bpm.py").read_text().lower()
        self.assertNotIn("librosa", text)


class TestBpmCheck(unittest.TestCase):
    """`bpm.py --check` is Doctor's question: exactly analyzer_ready(), no file, nothing on stdout."""

    def test_complete_install_exits_zero(self):
        p = subprocess.run([sys.executable, str(ROOT / "bpm.py"), "--check"],
                           capture_output=True, text=True, timeout=120)
        self.assertEqual((p.returncode, p.stdout, p.stderr), (0, "", ""))

    def test_missing_model_gives_the_sentence_and_the_incomplete_code(self):
        p = run_bpm(_CHECK_NO_MODEL)
        self.assertEqual(p.returncode, 2, (p.stdout, p.stderr))
        self.assertEqual(p.stdout, "")
        self.assertEqual(p.stderr.strip(), MESSAGE)

    def test_no_essentia_gives_the_sentence_and_the_incomplete_code(self):
        p = run_bpm(_CHECK_NO_ESSENTIA)
        self.assertEqual(p.returncode, 2, (p.stdout, p.stderr))
        self.assertEqual(p.stderr.strip(), MESSAGE)


if __name__ == "__main__":
    unittest.main()
