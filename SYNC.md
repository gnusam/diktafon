# Laptop sync (fork)

Upstream Diktafon keeps everything in app-private storage — no storage
permission, no FileProvider, `run-as` refused on a release build. Nothing
short of an in-app export to `Download` gets a memo off the phone, which is
one manual step too many for field notes you want on the laptop the same
evening.

This fork adds an **opt-in** send: as soon as a memo is written up, it posts
itself to a receiver on your own machine, and the receiver files it as the
exact directory an export would have produced.

    phone ──HTTPS──▶ diktafon.tunnel.example.fr (Traefik, Let's Encrypt)
                          │
                          ▼
                     frps ──tunnel──▶ frpc ──▶ receiver ──▶ ~/dev/perso/<label>/retex/diktafon/
                                     └─ on the laptop, mains power only ─┘

The server in the middle **routes and stores nothing**: memos exist on the
phone and on the laptop, nowhere else.

## Setting it up

### 1. The receiver, on the laptop

```bash
cd tools/laptop-receiver
cp .env.example .env                 # uid/gid, hostname, optional token
cp frpc.toml.example frpc.toml       # tunnel server, its token, basic auth
docker compose up -d
```

`.env` and `frpc.toml` are gitignored — they hold the only secrets involved.
Without Docker, the receiver is a single dependency-free file:

```bash
DIKTAFON_TOKEN=… python3 tools/laptop-receiver/receiver.py
```

### 2. Mains-only

The stack is `restart: "no"`; a small guard owns when it runs, so a laptop
that boots on battery does not open a tunnel:

```bash
tools/laptop-receiver/power-guard/install.sh    # user timer, no root
```

On battery the tunnel closes and the phone keeps its memos queued — they go
up within a minute of the cable going back in. `99-diktafon-power.rules`
makes that reaction instant instead, at the cost of one root-owned file.

### 3. The phone

Settings → **Laptop sync** → *Laptop address*, and paste one string:

```
https://user:password@diktafon.tunnel.example.fr#optional-token
```

- the credentials are the tunnel's basic auth (`httpUser`/`httpPassword`);
- the fragment is `DIKTAFON_TOKEN`, if you set one. It rides in the fragment
  because a fragment is never sent over the wire: a token in the path would
  land in the reverse proxy's access log on the server.

**Test** answers with the receiving machine's own hostname, so you can see
*which* laptop you just reached. Then turn *Send automatically* on.

## What happens next

- A memo is queued for sending when it reaches its final content — after the
  gist, and after the WAV→AAC transcode, so the archival `.m4a` is what
  travels.
- **An unreachable laptop is not an error.** The job is parked and retried
  (30 s, then longer, capped at a quarter of an hour), across app restarts,
  for as long as it takes. Memos stay marked ↑ until they land; Settings
  shows how many are waiting.
- The one failure that gives up is a *refusal* — 401/403. Retrying a
  rejection forever would only hide it.
- Turning sync on does **not** push everything you ever recorded: the
  automatic sweep at launch only reaches back a week (it exists to catch a
  memo whose job was lost to a kill). Older ones go when you ask — the
  Settings row, or a cassette's *Send to laptop*.
- Editing a transcript un-marks the memo: the laptop's copy describes the
  old words, so it is sent again.
- A cassette's ⋮ menu has **Send to laptop**, which re-sends the whole tape,
  acknowledged memos included. The receiver is idempotent by memo id, so
  "send it again" is always safe.

## What lands on the laptop

A cassette named after a directory in `~/dev/perso` goes to that project's
`retex/diktafon/<label>/`; anything else goes to `~/diktafon-inbox/<label>/`.

```
life/
├── audio/memo_2026-08-20_17-40-04_64777cd9.m4a
├── cassette.json      # the export's shape: word-level transcripts included
├── transcript.md      # readable, memos numbered in tape order
└── .memos/            # one fragment per memo — the two files above are
                       # rebuilt from these on every arrival
```

Audio file names come from the recording's own time plus a slice of its id:
stable for the life of the memo, so a re-send overwrites in place and
nothing is ever renamed underneath you. (An export numbers them
`memo-001_…` instead; nothing reads that number.)

## Security

The endpoint is reachable from the internet, so:

- **basic auth at the tunnel** rejects unauthenticated requests on the
  server, before they ever reach the laptop;
- **the token**, when set, is checked with a constant-time compare;
- every path component is **re-derived locally** from a strict whitelist —
  a cassette named `../../etc/cron.d/pwn` becomes `etc-cron.d-pwn` in the
  inbox, and a memo id with a path in it is refused outright;
- audio is written to a staging file inside the destination and renamed into
  place, after its **SHA-256** is checked against the manifest;
- bodies are bounded (`DIKTAFON_MAX_BYTES`, 512 MiB by default) before a
  byte is read.

TLS terminates on the server, so the audio is briefly in clear *in memory*
there before re-entering the (encrypted) tunnel; it is never written to the
server's disk.

## When something does not arrive

```bash
docker compose logs -f receiver                    # what the laptop sees
docker compose logs frpc                           # is the tunnel up
curl -u user:pass https://…/v1/ping -H "X-Diktafon-Token: …"
dart run tools/laptop-receiver/sync_probe.dart '<the pasted url>' probe
python3 tools/laptop-receiver/test_receiver.py     # the receiver's own tests
```

`sync_probe` sends a synthetic memo through the app's real client and payload
builder: if it arrives and the phone's do not, the problem is on the phone,
not in the tunnel.

`~/.local/bin/diktafon-pull` still works and needs none of this — it is the
fallback when the tunnel is down and the memo is needed now.
