#!/usr/bin/env python3
"""Self-test for the receiver: `python3 test_receiver.py`.

Standard library only, like the thing it tests. Starts a real receiver on a
free port, talks to it over HTTP, and checks both what it files and what it
refuses — the refusals matter most, since this endpoint is reachable from
the internet through the tunnel.
"""

from __future__ import annotations

import hashlib
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOKEN = "tok-selftest"
failures: list[str] = []


def check(label: str, got, want) -> None:
    if got == want:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label}\n       got  {got!r}\n       want {want!r}")
        failures.append(label)


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def multipart(manifest: dict, audio: bytes | None) -> tuple[bytes, str]:
    boundary = "----selftest-boundary"
    body = b"".join([
        f"--{boundary}\r\n".encode(),
        b'Content-Disposition: form-data; name="manifest"; filename="manifest.json"\r\n',
        b"Content-Type: application/json; charset=utf-8\r\n\r\n",
        json.dumps(manifest).encode("utf-8"),
        *(
            [
                f"\r\n--{boundary}\r\n".encode(),
                b'Content-Disposition: form-data; name="audio"; filename="a.m4a"\r\n',
                b"Content-Type: application/octet-stream\r\n\r\n",
                audio,
            ]
            if audio is not None
            else []
        ),
        f"\r\n--{boundary}--\r\n".encode(),
    ])
    return body, f"multipart/form-data; boundary={boundary}"


def post(port: int, manifest: dict, audio: bytes | None, token: str = TOKEN,
         path: str = "/v1/memo") -> tuple[int, dict]:
    body, content_type = multipart(manifest, audio)
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", data=body, method="POST",
        headers={"Content-Type": content_type,
                 "Content-Length": str(len(body)),
                 "X-Diktafon-Token": token})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            return error.code, json.loads(raw)
        except json.JSONDecodeError:
            return error.code, {"raw": raw.decode("utf-8", "replace")}


def memo(memo_id: str, created: str, body: str, label: str = "life",
         summary: str | None = None, audio: bytes = b"\0" * 32,
         sha: str | None = None) -> dict:
    return {
        "syncVersion": 1,
        "formatVersion": 1,
        "cassette": {
            "id": "c1", "label": label, "titleIsUserSet": True,
            "colorSeed": 60964, "summary": "Retours terrain.",
            "summaryUpdatedAt": None,
            "createdAt": "2026-08-20T17:38:45.662",
            "updatedAt": "2026-08-20T17:40:27.076",
        },
        "memo": {
            "id": memo_id, "createdAt": created, "durationMs": 36240,
            "language": "fr", "summary": summary,
            "transcript": {"lang": "fr", "segments": []},
        },
        "render": {
            "untitled": "Cassette sans titre", "summaryHeading": "Résumé",
            "headingTemplate": "Mémo {n} — {date}",
            "noteTemplate": "Exporté depuis Diktafon le {date}.",
            "stamp": f"{created[:10]} {created[11:16]}",
            "body": (f"> {summary}\n\n" if summary else "") + body,
        },
        "audio": {"ext": ".m4a", "bytes": len(audio),
                  "sha256": sha or hashlib.sha256(audio).hexdigest()},
    }


def send(port: int, memo_id: str, created: str, body: str,
         audio: bytes = b"audio", token: str = TOKEN, path: str = "/v1/memo",
         **kwargs) -> tuple[int, dict]:
    """Builds a manifest that describes exactly the audio it sends — a
    mismatch is a case to test on purpose, never an accident of the harness."""
    return post(port, memo(memo_id, created, body, audio=audio, **kwargs),
                audio, token=token, path=path)


def main() -> int:
    work = Path(tempfile.mkdtemp(prefix="diktafon-selftest-"))
    tmpdir = work / "tmp"
    for sub in ("projects/life", "inbox", "tmp"):
        (work / sub).mkdir(parents=True)
    port = free_port()

    env = {
        **os.environ,
        "DIKTAFON_PORT": str(port),
        "DIKTAFON_BIND": "127.0.0.1",
        "DIKTAFON_PROJECTS": str(work / "projects"),
        "DIKTAFON_INBOX": str(work / "inbox"),
        "DIKTAFON_TOKEN": TOKEN,
        "DIKTAFON_NOTIFY": "0",
        "TMPDIR": str(tmpdir),
    }
    server = subprocess.Popen(
        [sys.executable, str(HERE / "receiver.py")], env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        for _ in range(50):
            try:
                with urllib.request.urlopen(
                        urllib.request.Request(
                            f"http://127.0.0.1:{port}/v1/ping",
                            headers={"X-Diktafon-Token": TOKEN}),
                        timeout=1) as response:
                    check("ping answers with a host name",
                          "host" in json.loads(response.read()), True)
                    break
            except (urllib.error.URLError, ConnectionError, TimeoutError):
                time.sleep(0.1)
        else:
            print("receiver never came up")
            return 1

        audio_one = b"first-memo-audio" * 4
        status, _ = send(port, "m-0001", "2026-08-20T17:40:04.942",
                         "Le bouton est perturbant.", audio_one,
                         summary="Renommer le bouton.")
        check("a memo is accepted", status, 200)

        dest = work / "projects/life/retex/diktafon/life"
        check("it lands in the project's retex tree", dest.is_dir(), True)
        check("the audio keeps its bytes",
              (dest / "audio/memo_2026-08-20_17-40-04_m-0001.m4a").read_bytes(),
              audio_one)

        status, _ = send(port, "m-0002", "2026-08-20T18:02:11.100",
                         "Deuxième mémo.", b"second")
        check("a second memo joins it", status, 200)
        # …and one recorded earlier that only arrives now: the numbering is
        # the tape's, not the arrival order's.
        send(port, "m-0000", "2026-08-20T09:15:00.000", "Le matin.", b"early")
        headings = [line for line in
                    (dest / "transcript.md").read_text("utf-8").splitlines()
                    if line.startswith("## Mémo")]
        check("headings are renumbered in tape order", headings,
              ["## Mémo 1 — 2026-08-20 09:15",
               "## Mémo 2 — 2026-08-20 17:40",
               "## Mémo 3 — 2026-08-20 18:02"])

        manifest = json.loads((dest / "cassette.json").read_text("utf-8"))
        check("cassette.json lists the tape in order",
              [m["id"] for m in manifest["memos"]],
              ["m-0000", "m-0001", "m-0002"])
        check("each memo points at its own audio",
              manifest["memos"][1]["audio"],
              "audio/memo_2026-08-20_17-40-04_m-0001.m4a")

        # Re-sending a memo replaces it in place — the app does this after a
        # transcript edit, and after any "send again".
        send(port, "m-0001", "2026-08-20T17:40:04.942", "Texte corrigé.",
             audio_one, summary="Renommer le bouton.")
        text = (dest / "transcript.md").read_text("utf-8")
        check("a re-send replaces rather than duplicates",
              (text.count("Texte corrigé."), text.count("Le bouton est perturbant.")),
              (1, 0))
        check("no memo was added by the re-send",
              len(list((dest / ".memos").glob("*.json"))), 3)

        # An export already sitting where memos now land (the old manual
        # route wrote the same file names) must survive first contact.
        older = work / "projects/old/retex/diktafon/old"
        older.mkdir(parents=True)
        (older / "transcript.md").write_text("# old\n\nfrom a manual export\n")
        (older / "cassette.json").write_text('{"label": "old"}')
        send(port, "m-old", "2026-08-20T11:00:00.000", "Nouveau mémo.",
             label="old")
        check("an existing export is kept, not overwritten",
              (older / "transcript.md.before-sync").read_text().strip(),
              "# old\n\nfrom a manual export".strip())
        check("and the rebuilt transcript is the synced one",
              "Nouveau mémo." in (older / "transcript.md").read_text(), True)

        # ---- what it must refuse ----------------------------------------
        status, body = send(port, "m-9", "2026-08-20T10:00:00.000", "x",
                            b"tampered", sha="0" * 64)
        check("a mismatched checksum is refused", (status, body["error"]),
              (400, "audio checksum mismatch"))

        status, _ = send(port, "../../escape", "2026-08-20T10:00:00.000", "x")
        check("a memo id with a path in it is refused", status, 400)

        status, _ = send(port, "m-evil", "2026-08-20T10:00:00.000", "x",
                         label="../../../../etc/cron.d/pwn")
        check("a hostile cassette name is flattened, not followed", status, 200)
        check("nothing escaped the inbox",
              sorted(p.name for p in (work / "inbox").iterdir()),
              ["etc-cron.d-pwn"])
        check("no directory appeared outside the roots",
              sorted(p.name for p in work.iterdir()),
              ["inbox", "projects", "tmp"])

        status, _ = send(port, "m-8", "2026-08-20T10:00:00.000", "x",
                         token="wrong")
        check("a wrong token is refused", status, 403)

        status, _ = send(port, "m-7", "2026-08-20T10:00:00.000", "x",
                         path="/v1/elsewhere")
        check("an unknown route is refused", status, 404)

        check("refused uploads left no temp files behind",
              sorted(p.name for p in tmpdir.iterdir()), [])
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()

    print()
    if failures:
        print(f"{len(failures)} failing check(s): {', '.join(failures)}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
