#!/usr/bin/env python3
"""
The Beat Key app's download helper. The Swift app spawns this and renders its JSON-lines events.

  app_run.py download <url> [--cookies-file <path>]
  app_run.py --check          (exit 0 = this helper and what it imports start; Run Doctor asks)

One JSON object per stdout line, flushed. Exit code 0 unless the process itself crashed.
A good download ends with {"stage": "downloaded", "file": <path>}: the app then reads the file
with its analysis core, tags its name and adds the entry to the links log (FileJobs.swift). Reading
files, the tag and the rename moved into the app with the core (plug-in plan step 19); this helper
only downloads. The Downloads folder comes from ORION_DOWNLOADS (default ~/Downloads).
ORION_YTDLP = the yt-dlp to use (the app's copy in Application Support); unset or missing = the
one on PATH. This script never upgrades it: the app does that at launch (weekly) and in Run Doctor.
ORION_YTDLP_TIMEOUT = seconds allowed per yt-dlp call (default 600).
ORION_DENO = the bundled JavaScript runtime, passed to yt-dlp as --js-runtimes deno:<path>.
Every download writes its yt-dlp stderr to ~/Library/Logs/Beat Key/last-run.log (ORION_LOG_DIR
overrides the folder), overwritten each run.
"""

import contextlib
import io
import json
import os
import re
import sys
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import downloader  # noqa: E402


def log(msg):
    """One line to stderr, which the app sends to ~/Library/Logs/Beat Key/analyzer.log (timestamped,
    so it lines up with beatkey.log). Every failure that does not reach the app as an event lands here."""
    from datetime import datetime
    sys.stderr.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} app_run: {msg}\n")
    sys.stderr.flush()


def emit(**event):
    sys.stdout.write(json.dumps(event, ensure_ascii=False) + "\n")
    sys.stdout.flush()


YTDLP_TIMEOUT = 600


def ytdlp_path():
    """The app's yt-dlp (ORION_YTDLP) if it exists, else None."""
    p = os.environ.get("ORION_YTDLP")
    if p and os.path.isfile(p) and os.access(p, os.X_OK):
        return p
    return None


def ytdlp_timeout():
    try:
        return float(os.environ.get("ORION_YTDLP_TIMEOUT") or YTDLP_TIMEOUT)
    except ValueError:
        return YTDLP_TIMEOUT


def _attempt(url, cookies_file=None, raw=None):
    """One run_download pass. Returns (Path | None, message_text). raw (a list) receives yt-dlp's
    raw error lines."""
    out, err = io.StringIO(), io.StringIO()
    path = None
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            path = downloader.run_download(url, silent=True, app_order=True, ytdlp=ytdlp_path(),
                                           timeout=ytdlp_timeout(), cookies_file=cookies_file,
                                           raw_errors=raw)
        except Exception as exc:  # keep the process alive; report as a download error
            err.write(f"Download failed: {exc}\n")
    msg = (err.getvalue() or out.getvalue()).strip()
    return path, msg


LOGIN_MESSAGES = {
    "age": "This video is age-restricted. A YouTube login is needed.",
    "bot": "YouTube wants a login before it will serve this video.",
    "members": "This video is for channel members. A YouTube login is needed.",
}


def needs_login(reason, stale=False):
    """stale = the saved login was used and YouTube no longer takes it: the app deletes it and
    asks for a new one."""
    extra = {"stale": True} if stale else {}
    emit(stage="needs_login", reason=reason, message=LOGIN_MESSAGES[reason], **extra)


def keep_private(path):
    """yt-dlp writes the cookie jar back after a run; keep the file owner-only whatever it did."""
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


# The last download's yt-dlp stderr, overwritten every run, for whoever debugs the next failure.
# ORION_LOG_DIR overrides the folder (tests).
_REDACT = re.compile(r"(?i)\b(cookie|cookies|authorization|sapisid\w*|po_?token|visitor_?data|"
                     r"token|key|sig|signature)(\s*[=:]\s*)([^\s&,;'\"]+)")


def last_run_log_path():
    d = os.environ.get("ORION_LOG_DIR")
    base = Path(d) if d else Path.home() / "Library" / "Logs" / "Beat Key"
    return base / "last-run.log"


def write_last_run_log(url, cookies_file, outcome):
    try:
        lines = [f"Beat Key last run  {date.today().isoformat()}",
                 f"url: {url}", f"login: {'saved YouTube login' if cookies_file else '-'}", f"outcome: {outcome}", ""]
        for argv, code, err in downloader.RUN_LOG:
            lines.append(f"$ {' '.join(argv)}")
            lines.append(f"exit: {'timeout' if code is None else code}")
            lines.extend(_REDACT.sub(r"\1\2<redacted>", l) for l in err.splitlines())
            lines.append("")
        p = last_run_log_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    except Exception as exc:
        log(f"could not write last-run.log: {exc}")  # the log must never cost a download


def cmd_download(url, cookies_file=None):
    downloader.RUN_LOG.clear()
    outcome = ["crashed"]
    try:
        _cmd_download(url, cookies_file, outcome)
    finally:
        if cookies_file:
            keep_private(cookies_file)
        write_last_run_log(url, cookies_file, outcome[0])


def _cmd_download(url, cookies_file, outcome):
    emit(stage="downloading")
    raw = []
    path, msg = _attempt(url, cookies_file=cookies_file, raw=raw)
    if not path:
        reason = downloader.login_reason(raw)
        if cookies_file and (reason or downloader.cookies_stale(raw)):
            # the saved login did not get past YouTube: the app throws it away and asks again
            outcome[0] = "needs_login: saved login no longer works"
            needs_login(reason or "age", stale=True)
            return
        if reason:
            outcome[0] = f"needs_login: {reason}"
            needs_login(reason)
            return
    if not path:
        msg = msg or "Download failed for an unknown reason."
        outcome[0] = f"error: {msg}"
        log(f"download failed: {msg} (yt-dlp commands and their stderr: last-run.log)")
        emit(stage="error", message=msg)
        return
    outcome[0] = "downloaded"
    emit(stage="downloaded", file=str(path), name=path.name)


def main(argv):
    try:
        return _main(argv)
    except BaseException as exc:  # last resort: the app always gets a terminal event
        if isinstance(exc, KeyboardInterrupt):
            raise
        import traceback
        log("unexpected error: " + "".join(traceback.format_exception(type(exc), exc, exc.__traceback__)).strip())
        emit(stage="error", message=f"Unexpected error: {exc}")
        return 0


def _main(argv):
    if len(argv) == 2 and argv[1] == "--check":
        return 0                                    # imports done: python, downloader.py, this file
    if len(argv) >= 3 and argv[1] == "download":
        cookies_file = None
        if "--cookies-file" in argv[3:]:
            i = argv.index("--cookies-file", 3)
            cookies_file = argv[i + 1] if i + 1 < len(argv) else ""
            if not cookies_file or not os.path.isfile(cookies_file):
                # the saved login is gone: ask for one again rather than run without it
                needs_login("age", stale=True)
                return 0
        cmd_download(argv[2].strip(), cookies_file)
    else:
        emit(stage="error", message="usage: app_run.py download <url> [--cookies-file <path>] | --check")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
