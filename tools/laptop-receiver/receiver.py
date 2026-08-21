#!/usr/bin/env python3
"""Diktafon laptop receiver — the other end of the app's "send to laptop".

One phone, one laptop, one endpoint. The app posts a memo (its manifest,
and its audio); this files it under the cassette's name and keeps
`transcript.md` and `cassette.json` rebuilt so the directory is exactly what
an in-app export would have produced.

Standard library only, on purpose: it runs unattended on a laptop for
months, and a dependency that needs updating is a dependency that will not
be updated.

Environment:
  DIKTAFON_PORT        listen port                      (default 8099)
  DIKTAFON_BIND        listen address                   (default 0.0.0.0)
  DIKTAFON_PROJECTS    where per-project trees live     (default ~/dev/perso)
  DIKTAFON_INBOX       fallback drop                    (default ~/diktafon-inbox)
  DIKTAFON_TOKEN       required X-Diktafon-Token, if set
  DIKTAFON_MAX_BYTES   refuse bodies larger than this   (default 512 MiB)
  DIKTAFON_NOTIFY      1 → notify-send on arrival       (default 1)

Security note: this is reached from the internet through the tunnel. The
only inputs trusted here are the ones re-derived locally — every path
component is rebuilt from a strict whitelist, never from what the phone
sent, and the body is bounded before a byte of it is read.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("DIKTAFON_PORT", "8099"))
BIND = os.environ.get("DIKTAFON_BIND", "0.0.0.0")
PROJECTS = Path(os.environ.get("DIKTAFON_PROJECTS", "~/dev/perso")).expanduser()
INBOX = Path(os.environ.get("DIKTAFON_INBOX", "~/diktafon-inbox")).expanduser()
TOKEN = os.environ.get("DIKTAFON_TOKEN", "").strip()
MAX_BYTES = int(os.environ.get("DIKTAFON_MAX_BYTES", str(512 * 1024 * 1024)))
NOTIFY = os.environ.get("DIKTAFON_NOTIFY", "1") == "1"
HOSTNAME = os.environ.get("DIKTAFON_HOSTNAME", socket.gethostname())
# Where the phone's "put this cassette in that project" answers are kept.
ROUTES = Path(os.environ.get(
    "DIKTAFON_ROUTES", str(INBOX / ".routes.json"))).expanduser()
# In a container the paths above are mount points; these are the same
# places as the laptop's own user sees them, and the only ones worth
# showing on the phone ("/projects/life/…" means nothing to anybody).
PROJECTS_SHOWN = Path(
    os.environ.get("DIKTAFON_PROJECTS_DISPLAY") or PROJECTS).expanduser()
INBOX_SHOWN = Path(
    os.environ.get("DIKTAFON_INBOX_DISPLAY") or INBOX).expanduser()

# One cassette directory is rewritten in full on every arrival; two memos
# landing at once must not interleave their rebuilds.
RENDER_LOCK = threading.Lock()

# The one destination that is not a project directory.
INBOX_CHOICE = "@inbox"

SLUG_OK = re.compile(r"[^a-z0-9._-]+")
ID_OK = re.compile(r"\A[A-Za-z0-9_-]{1,64}\Z")
EXT_OK = re.compile(r"\A\.[a-z0-9]{1,5}\Z")
STAMP_OK = re.compile(r"[^0-9A-Za-z_-]+")


def log(message: str) -> None:
    print(f"{datetime.now():%Y-%m-%d %H:%M:%S} {message}", flush=True)


# --------------------------------------------------------------------------
# Multipart, read as a stream.
#
# A memo can be a hundred megabytes; none of it belongs in memory. The audio
# part is written straight to a temp file as it arrives.
# --------------------------------------------------------------------------


class BodyReader:
    def __init__(self, stream, length: int, chunk: int = 1 << 16):
        self.stream = stream
        self.remaining = length
        self.chunk = chunk
        self.buf = b""

    def _fill(self) -> bool:
        if self.remaining <= 0:
            return False
        data = self.stream.read(min(self.chunk, self.remaining))
        if not data:
            self.remaining = 0
            return False
        self.remaining -= len(data)
        self.buf += data
        return True

    def read_exact(self, n: int) -> bytes:
        while len(self.buf) < n:
            if not self._fill():
                raise ValueError("truncated body")
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def read_line(self) -> bytes:
        while b"\r\n" not in self.buf:
            if not self._fill():
                raise ValueError("truncated header")
        line, _, rest = self.buf.partition(b"\r\n")
        self.buf = rest
        return line

    def iter_until(self, delim: bytes):
        """Yields everything before [delim], then consumes it."""
        keep = len(delim) - 1
        while True:
            found = self.buf.find(delim)
            if found != -1:
                head = self.buf[:found]
                self.buf = self.buf[found + len(delim):]
                if head:
                    yield head
                return
            if len(self.buf) > keep:
                yield self.buf[:-keep]
                self.buf = self.buf[-keep:]
            if not self._fill():
                raise ValueError("unterminated part")


def iter_parts(reader: BodyReader, boundary: bytes):
    delim = b"--" + boundary
    for _ in reader.iter_until(delim):  # preamble
        pass
    while True:
        lead = reader.read_exact(2)
        if lead == b"--":
            return
        if lead != b"\r\n":
            raise ValueError("malformed boundary")
        headers: dict[str, str] = {}
        while True:
            line = reader.read_line()
            if not line:
                break
            key, _, value = line.decode("utf-8", "replace").partition(":")
            headers[key.strip().lower()] = value.strip()
        disposition = headers.get("content-disposition", "")
        name = _disposition_value(disposition, "name")
        yield name, reader.iter_until(b"\r\n" + delim)


def _disposition_value(disposition: str, key: str) -> str:
    match = re.search(rf'{key}="([^"]*)"', disposition)
    return match.group(1) if match else ""


# --------------------------------------------------------------------------
# Filing
# --------------------------------------------------------------------------


def slugify(label: str | None, fallback: str = "cassette") -> str:
    slug = SLUG_OK.sub("-", (label or "").strip().lower()).strip("-._")
    return slug[:60] or fallback


def projects() -> list[str]:
    """The directories a cassette may be filed into — offered to the phone
    when it asks where to put one, and the *only* values a choice is
    accepted from. Names only: paths are rebuilt here."""
    try:
        return sorted(
            entry.name for entry in PROJECTS.iterdir()
            if entry.is_dir() and not entry.name.startswith(".")
        )
    except OSError:
        return []


def read_routes() -> dict[str, str]:
    try:
        routes = json.loads(ROUTES.read_text("utf-8"))
        return {k: v for k, v in routes.items() if isinstance(v, str)}
    except (OSError, json.JSONDecodeError, AttributeError):
        return {}


def in_project(name: str, slug: str) -> Path:
    return PROJECTS / name / "retex" / "diktafon" / slug


def resolve(slug: str) -> tuple[Path, bool]:
    """Where a cassette goes, and whether that was a *decision* or a guess.

    A decision is either the phone's own answer (kept in the routes file) or
    a project directory of exactly the cassette's name — the case where
    there is nothing to ask about. Anything else lands in the inbox and is
    reported as unresolved, so the phone can offer to place it."""
    route = read_routes().get(slug)
    if route == INBOX_CHOICE:
        return INBOX / slug, True
    if route and route in projects():
        return in_project(route, slug), True
    if (PROJECTS / slug).is_dir():
        return in_project(slug, slug), True
    return INBOX / slug, False


def set_route(slug: str, choice: str) -> Path:
    """Records the phone's answer and moves anything already filed under
    the old destination — a cassette placed after the fact must not leave
    half of itself behind."""
    if choice != INBOX_CHOICE and choice not in projects():
        raise ValueError("unknown destination")
    before, _ = resolve(slug)
    routes = read_routes()
    routes[slug] = choice
    write_atomic(ROUTES, (json.dumps(routes, indent=2, sort_keys=True) + "\n")
                 .encode("utf-8"))
    after, _ = resolve(slug)
    if before != after and before.exists():
        after.parent.mkdir(parents=True, exist_ok=True)
        if after.exists():
            # Merge: fragments carry everything, and render() rebuilds.
            for item in before.rglob("*"):
                target = after / item.relative_to(before)
                if item.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(item), str(target))
            shutil.rmtree(before, ignore_errors=True)
        else:
            shutil.move(str(before), str(after))
        render(after)
        log(f"  moved {before} → {after}")
    return after


def shown(path: Path) -> str:
    """A path as the laptop's user would type it."""
    for real, display in ((PROJECTS, PROJECTS_SHOWN), (INBOX, INBOX_SHOWN)):
        try:
            return str(display / path.relative_to(real))
        except ValueError:
            continue
    return str(path)


def write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def stamp_for(iso: str) -> str:
    """`2026-08-20T17:40:04.942` → `2026-08-20_17-40-04`, for file names."""
    try:
        moment = datetime.fromisoformat(iso)
    except ValueError:
        return "undated"
    return STAMP_OK.sub("", moment.strftime("%Y-%m-%d_%H-%M-%S"))


def render(dest: Path) -> tuple[int, str]:
    """Rebuilds `transcript.md` and `cassette.json` from every fragment on
    disk — the whole cassette, every time, so a re-sent or corrected memo
    lands in the right place with the numbering fixed up."""
    fragments = []
    for path in sorted((dest / ".memos").glob("*.json")):
        try:
            fragments.append(json.loads(path.read_text("utf-8")))
        except (OSError, json.JSONDecodeError):
            log(f"! unreadable fragment {path.name} — skipped")
    fragments.sort(key=lambda f: (f["memo"]["createdAt"], f["memo"]["id"]))
    if not fragments:
        return 0, ""

    newest = fragments[-1]
    cassette = newest["cassette"]
    render_hints = newest.get("render", {})
    label = cassette.get("label") or render_hints.get("untitled", "Untitled cassette")
    now = f"{datetime.now():%Y-%m-%d %H:%M}"

    note = render_hints.get("noteTemplate", "Received from Diktafon on {date}.")
    lines = [f"# {label}", "", note.replace("{date}", now), ""]
    if cassette.get("summary"):
        lines += [f"## {render_hints.get('summaryHeading', 'Summary')}", "",
                  cassette["summary"], ""]

    memos = []
    heading = render_hints.get("headingTemplate", "Memo {n} — {date}")
    for index, fragment in enumerate(fragments, start=1):
        hints = fragment.get("render", {})
        title = hints.get("headingTemplate", heading)
        title = title.replace("{n}", str(index)).replace("{date}", hints.get("stamp", ""))
        lines += [f"## {title}", "", hints.get("body", ""), ""]
        memo = dict(fragment["memo"])
        memo["audio"] = f"audio/{fragment['audioName']}" if fragment.get("audioName") else None
        memos.append(memo)

    write_atomic(dest / "transcript.md", "\n".join(lines).encode("utf-8"))
    write_atomic(
        dest / "cassette.json",
        (json.dumps(
            {
                "formatVersion": newest.get("formatVersion", 1),
                "label": cassette.get("label"),
                "titleIsUserSet": cassette.get("titleIsUserSet"),
                "colorSeed": cassette.get("colorSeed"),
                "summary": cassette.get("summary"),
                "summaryUpdatedAt": cassette.get("summaryUpdatedAt"),
                "createdAt": cassette.get("createdAt"),
                "updatedAt": cassette.get("updatedAt"),
                "receivedAt": datetime.now().isoformat(timespec="seconds"),
                "memos": memos,
            },
            indent=2,
            ensure_ascii=False,
        ) + "\n").encode("utf-8"),
    )
    return len(fragments), label


def notify(title: str, body: str) -> None:
    if not NOTIFY or not shutil.which("notify-send"):
        return
    try:
        subprocess.run(
            ["notify-send", "-a", "Diktafon", title, body],
            check=False, timeout=5, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.SubprocessError):
        pass  # a missing desktop session must never fail an upload


class Handler(BaseHTTPRequestHandler):
    server_version = "diktafon-receiver/1"
    protocol_version = "HTTP/1.1"

    # ---- plumbing --------------------------------------------------------

    def log_message(self, fmt, *args):  # noqa: A003 - BaseHTTPRequestHandler API
        log(f"{self.address_string()} {fmt % args}")

    def _json(self, status: int, payload: dict) -> None:
        body = (json.dumps(payload) + "\n").encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        if not TOKEN:
            return True
        return hmac.compare_digest(
            self.headers.get("X-Diktafon-Token", ""), TOKEN)

    def _drain(self) -> None:
        """A refused request still has to be read, or the client sees a
        connection reset instead of the status it was told."""
        length = int(self.headers.get("Content-Length") or 0)
        remaining = min(length, MAX_BYTES)
        while remaining > 0:
            chunk = self.rfile.read(min(1 << 16, remaining))
            if not chunk:
                break
            remaining -= len(chunk)

    # ---- routes ----------------------------------------------------------

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        path, _, query = self.path.partition("?")
        path = path.rstrip("/")
        if path.endswith("/v1/ping"):
            if not self._authorized():
                return self._json(403, {"error": "bad token"})
            return self._json(200, {"host": HOSTNAME, "receiver": 1})
        if path.endswith("/v1/destination"):
            if not self._authorized():
                return self._json(403, {"error": "bad token"})
            label = urllib.parse.parse_qs(query).get("label", [""])[0]
            slug = slugify(label)
            dest, known = resolve(slug)
            # The phone shows these as the places a cassette can live; it
            # sends one back by name, never a path.
            return self._json(200, {
                "slug": slug,
                "known": known,
                "path": shown(dest),
                "inbox": INBOX_CHOICE,
                "choices": projects(),
            })
        self._json(404, {"error": "no such endpoint"})

    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler API
        path = self.path.partition("?")[0].rstrip("/")
        if path.endswith("/v1/destination"):
            if not self._authorized():
                self._drain()
                return self._json(403, {"error": "bad token"})
            length = min(int(self.headers.get("Content-Length") or 0), 64 * 1024)
            try:
                body = json.loads(self.rfile.read(length).decode("utf-8"))
                slug = slugify(str(body.get("label", "")))
                with RENDER_LOCK:
                    dest = set_route(slug, str(body.get("choice", "")))
            except (ValueError, json.JSONDecodeError, UnicodeDecodeError) as e:
                return self._json(400, {"error": str(e)})
            log(f"= {slug} → {shown(dest)}")
            return self._json(200, {"slug": slug, "path": shown(dest)})
        if not path.endswith("/v1/memo"):
            self._drain()
            return self._json(404, {"error": "no such endpoint"})
        if not self._authorized():
            self._drain()
            return self._json(403, {"error": "bad token"})

        content_type = self.headers.get("Content-Type", "")
        match = re.search(r'boundary=("?)([^";]+)\1', content_type)
        if not match:
            self._drain()
            return self._json(400, {"error": "expected multipart/form-data"})
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return self._json(411, {"error": "Content-Length required"})
        if length > MAX_BYTES:
            self._drain()
            return self._json(413, {"error": f"body over {MAX_BYTES} bytes"})

        try:
            self._store(BodyReader(self.rfile, length),
                        match.group(2).encode("utf-8"))
        except ValueError as error:
            return self._json(400, {"error": str(error)})
        except Exception as error:  # noqa: BLE001 - the phone deserves an answer
            log(f"! {error!r}")
            return self._json(500, {"error": "receiver failed"})

    def _store(self, reader: BodyReader, boundary: bytes) -> None:
        """Reads one upload and files it. The audio lands in a temp file
        first: a manifest that turns out to be unusable must not leave a
        stray half-memo behind in /tmp."""
        holder: list[Path] = []
        try:
            self._store_parts(reader, boundary, holder)
        finally:
            for leftover in holder:
                leftover.unlink(missing_ok=True)

    def _store_parts(self, reader: BodyReader, boundary: bytes,
                     holder: list[Path]) -> None:
        manifest: dict | None = None
        audio_tmp: Path | None = None
        audio_bytes = 0
        digest = hashlib.sha256()

        for name, chunks in iter_parts(reader, boundary):
            if name == "manifest":
                raw = b"".join(chunks)
                manifest = json.loads(raw.decode("utf-8"))
            elif name == "audio":
                handle, tmp_path = tempfile.mkstemp(prefix="diktafon-", suffix=".part")
                audio_tmp = Path(tmp_path)
                holder.append(audio_tmp)
                with os.fdopen(handle, "wb") as out:
                    for chunk in chunks:
                        audio_bytes += len(chunk)
                        digest.update(chunk)
                        out.write(chunk)
            else:
                for _ in chunks:  # unknown part: consumed, ignored
                    pass

        if not isinstance(manifest, dict):
            raise ValueError("no manifest")
        memo = manifest.get("memo") or {}
        memo_id = str(memo.get("id", ""))
        if not ID_OK.match(memo_id):
            raise ValueError("bad memo id")

        expected = (manifest.get("audio") or {}).get("sha256")
        if audio_tmp is not None and expected and digest.hexdigest() != expected:
            raise ValueError("audio checksum mismatch")

        slug = slugify((manifest.get("cassette") or {}).get("label"))
        dest, _ = resolve(slug)
        with RENDER_LOCK:
            count, label, audio_bytes = self._file_memo(
                manifest, memo, memo_id, dest, audio_tmp, audio_bytes, holder)
        log(f"+ {label or slug}: memo {memo_id[:8]} "
            f"({audio_bytes // 1024} KiB) → {shown(dest)} [{count} memo(s)]")
        notify(f"Diktafon — {label or slug}",
               f"{count} memo(s) in {shown(dest)}")
        self._json(200, {"ok": True, "path": shown(dest), "memos": count})

    def _file_memo(self, manifest, memo, memo_id, dest: Path,
                   audio_tmp: Path | None, audio_bytes: int,
                   holder: list[Path]):
        # First memo into a directory that already holds an export (the old
        # manual `diktafon-pull` route wrote the same two file names): keep
        # it. From here on these files are rebuilt from fragments, and a
        # rebuild only knows about memos that came through the tunnel — it
        # would quietly drop everything the export had put there.
        if not (dest / ".memos").exists():
            for name in ("transcript.md", "cassette.json"):
                existing = dest / name
                if existing.exists():
                    kept = dest / f"{name}.before-sync"
                    existing.replace(kept)
                    log(f"  kept the existing {name} as {kept.name}")
        (dest / ".memos").mkdir(parents=True, exist_ok=True)

        audio_name = None
        if audio_tmp is not None:
            ext = (manifest.get("audio") or {}).get("ext", ".m4a")
            if not EXT_OK.match(str(ext)):
                ext = ".bin"
            # Named from the recording's own time plus a slice of its id:
            # stable for the life of the memo, so a re-send overwrites in
            # place and nothing is ever renamed underneath the user.
            audio_name = f"memo_{stamp_for(str(memo.get('createdAt', '')))}_{memo_id[:8]}{ext}"
            audio_dir = dest / "audio"
            audio_dir.mkdir(parents=True, exist_ok=True)
            # In a container the temp file and the destination are on
            # different filesystems, so a bare rename raises EXDEV: stage
            # the file *inside* the destination first (a copy, wherever it
            # came from), then rename over the final name — that last step
            # is the atomic one, and a half-written audio never appears
            # under a name anything reads.
            staged = audio_dir / f".{audio_name}.part"
            holder.append(staged)
            shutil.move(str(audio_tmp), str(staged))
            os.replace(staged, audio_dir / audio_name)
        else:
            # Audio-less re-send of a memo we already hold: keep the file
            # that is already on disk rather than dropping it.
            previous = dest / ".memos" / f"{memo_id}.json"
            if previous.exists():
                try:
                    audio_name = json.loads(previous.read_text("utf-8")).get("audioName")
                except (OSError, json.JSONDecodeError):
                    audio_name = None

        fragment = dict(manifest)
        fragment["audioName"] = audio_name
        fragment["receivedAt"] = datetime.now().isoformat(timespec="seconds")
        write_atomic(
            dest / ".memos" / f"{memo_id}.json",
            (json.dumps(fragment, indent=2, ensure_ascii=False) + "\n").encode("utf-8"),
        )

        count, label = render(dest)
        return count, label, audio_bytes


def main() -> int:
    INBOX.mkdir(parents=True, exist_ok=True)
    log(f"listening on {BIND}:{PORT} — projects={PROJECTS} inbox={INBOX} "
        f"token={'set' if TOKEN else 'none'}")
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("stopped")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
