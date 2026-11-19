"""downloader.py, the command-line tool's downloader (run.sh). The Beat Key app's download is
Swift since plug-in plan step 19 (app/Sources/Orion/Downloader.swift, tested by DownloaderTests);
app_run.py, the old app helper, is gone. Run with any Python 3:
python3 -m unittest discover -s tests"""
import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
STUB_DIR = ROOT / "tests" / "stub"

import downloader  # noqa: E402


class TestStrategies(unittest.TestCase):
    def test_the_cli_order_is_the_original_one(self):
        self.assertEqual(downloader.strategies(), [
            ["--cookies-from-browser", "firefox"],
            ["--cookies-from-browser", "safari"],
            ["--cookies-from-browser", "chrome"],
            ["--extractor-args", "youtube:player_client=android"],
            ["--extractor-args", "youtube:player_client=web"],
            [],
        ])

    def test_every_strategy_is_tried_cookies_first_with_no_app_flags(self):
        calls = []

        def fake_fetch(url, extra_args=()):
            calls.append(tuple(extra_args))
            return None, ["ERROR: Video unavailable"]
        with mock.patch.dict(os.environ, {"ORION_DENO": "/bin/sh"}), \
                mock.patch.object(downloader, "fetch_info", fake_fetch), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertIsNone(downloader.run_download("https://example.com/v", silent=True))
        self.assertEqual(len(calls), 6)
        self.assertEqual(calls[0], ("--cookies-from-browser", "firefox"))
        self.assertFalse(any("--js-runtimes" in c for c in calls))

    def test_the_app_only_pieces_are_gone(self):
        for name in ("RUN_LOG", "YtDlpTimeout", "js_runtime_args", "login_reason", "cookies_stale"):
            self.assertFalse(hasattr(downloader, name), name)
        self.assertFalse((ROOT / "app_run.py").exists())


class TestErrors(unittest.TestCase):
    def test_error_mapping_uses_ytdlp_wording(self):
        e = downloader.explain_error
        self.assertEqual(e(["ERROR: [youtube] x: Requested format is not available."]), downloader.BLOCKED_MESSAGE)
        self.assertEqual(e(["ERROR: [youtube] x: Video unavailable. This video has been removed by the uploader"]),
                         downloader.UNAVAILABLE_MESSAGE)
        self.assertEqual(e(["ERROR: [youtube] x: Private video. Sign in if you've been granted access"]),
                         downloader.PRIVATE_MESSAGE)
        self.assertTrue(e(["ERROR: Unable to download webpage: <urlopen error>"]).startswith("Network error"))
        self.assertFalse(e(["WARNING: Only images are available"]).startswith("That video is age"))


class TestCli(unittest.TestCase):
    def test_a_download_through_the_stub_prints_the_path(self):
        with tempfile.TemporaryDirectory() as d:
            audio = Path(d) / "a.mp3"
            audio.write_bytes(b"x")
            env = dict(os.environ, PATH=f"{STUB_DIR}{os.pathsep}{os.environ.get('PATH', '')}", STUB_MODE="ok",
                       STUB_AUDIO=str(audio), STUB_STATE=d, ORION_DOWNLOADS=d)
            p = subprocess.run([sys.executable, str(ROOT / "downloader.py"), "https://example.com/v"],
                               capture_output=True, text=True, env=env, timeout=60)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stdout.strip(), str(Path(d) / "Test Beat.mp3"))
            self.assertTrue((Path(d) / "Test Beat.mp3").is_file())


if __name__ == "__main__":
    unittest.main()
