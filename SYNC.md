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

### 3. Pairing the phone

There is no clipboard between the two machines, and the address carries a
password. So the laptop shows it as a QR code:

```bash
tools/laptop-receiver/pair-qr.sh        # in the terminal
tools/laptop-receiver/pair-qr.sh -p     # …or as a PNG, for a small terminal
```

On the phone: Settings → **Laptop sync** → *Laptop address* → **SCAN**.

The address it encodes is `https://user:password@host#token` —
credentials are the tunnel's basic auth (`httpUser`/`httpPassword`), and the
fragment is `DIKTAFON_TOKEN` when you set one. It rides in the fragment
because a fragment is never sent over the wire: a token in the path would
land in the reverse proxy's access log on the server. The field also takes a
typed address, for a desktop build or a laptop on the LAN.

**Test** answers with the receiving machine's own hostname, so you can see
*which* laptop you just reached. Then turn *Send automatically* on.

## What happens next

- A memo is queued for sending when it reaches its final content — after the
  gist, and after the WAV→AAC transcode, so the archival `.m4a` is what
  travels.
- **A finished memo leaves before the next whisper pass starts.** The drain
  picks uploads ahead of everything else (oldest first among themselves):
  an upload is seconds and never gated, a transcription is minutes and may
  wait hours on the battery gate, and a long session leaves a queue of
  them. Before this, "done transcribing" and "on the laptop" could drift
  hours apart. The launch sweep leaves a memo still waiting on whisper to
  its own pipeline rather than send it half-made.
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

## Leaving the app, and what keeps running

Record, swipe away, get on with your day: the transcription, the gist, the
transcode and the upload all finish without you. That is not free on Android
— a backgrounded app is a *cached* app, and the OS freezes its threads
within seconds. Jobs were always durable, but frozen ones make no progress,
so a memo left behind used to sit half-transcribed until the app was next
opened.

So the queue holds a `dataSync` foreground service for exactly as long as it
has a job in hand: **"Finalisation des mémos"** in the notification shade is
the app working while you are elsewhere. It appears only when there is real
work, and goes as soon as the queue runs dry — the launch drain that finds
nothing to do never raises it. While whisper is on a memo the notification
also carries its progress — "transcription en cours… 42 %" and a bar —
the same figure the memo shows under its heading and its cassette's card
shows on the home grid. It is whisper's own number, reported once per
~30 s decoding window, so a short memo may finish before it ever moves.

Two things it deliberately does **not** do:

- **It does not survive the queue going idle.** A memo parked for an absent
  laptop is retried while the app lives, but once the process is frozen (or
  killed) the retry waits for the next launch. Holding a service open for a
  laptop that may be off all day would cost battery, and Android meters
  `dataSync` at six hours a day besides.
- **It cannot start from the background.** Android only lets a foreground
  app raise one. In practice the queue always claims it at record-stop —
  with the app on screen, or with the microphone service still holding the
  process foreground when a phone call ends the capture behind your back.

Battery optimisation for the app is worth turning off if you record long
memos on an aggressive OEM ROM (Xiaomi, Samsung, Huawei): the service asks
the OS not to freeze the process, it does not stop the OEM killing it.
None of this applies to iOS, which suspends the process whatever we ask, or
to desktop, which never pauses.

## The battery gate

Whisper and the local LLM are the two things here that genuinely cost a
phone: minutes of pinned CPU, a warm case, a visible dent in the curve.
**Below 20 % on battery they wait.** A charger overrides it at any level —
plugged in at 3 %, everything runs.

What is *not* gated, on purpose:

- **The upload.** A finished memo reaching the laptop is a few hundred
  kilobytes over HTTPS, nothing next to an inference pass. Holding it back
  on low battery would recreate the exact symptom the section above exists
  to remove, with a percentage as the trigger instead of a frozen process.
  A memo enriched yesterday goes today at 3 %.
- **Recording.** Capturing a thought works at 3 % or it is not a voice
  recorder.
- **The WAV→AAC transcode.** Hardware MediaCodec, seconds of work — and it
  produces the very file the upload carries.

A memo the gate is holding says so, rather than showing the "queued for
transcription…" it would show for any other wait: *waiting for power —
transcribing again above 20%*. Settings → Intelligence → **Energy** carries
the same state, and the count of what is waiting. That honesty is the point:
after the freeze bug, a memo silent for an hour with no explanation is
indistinguishable from a broken one.

The gate is re-read on every pass of the drain, so plugging in releases the
backlog between two jobs — never mid-inference, so no work is thrown away —
and the phone going on the charger wakes the queue by itself, without the
app being opened. The threshold is fixed at 20 %; there is nothing to
configure, and the only lever is a cable.

## Sending a cassette, and where it goes

Sending is a cassette's own affair — its ⋮ menu, **Send to laptop** — not a
Settings chore, because that is where the cassette (and so its destination)
is known. It re-sends the whole tape, acknowledged memos included: the
receiver is idempotent by memo id, so "send it again" is always safe.

What happens then depends on whether the laptop already has a place for it:

- **It does** → the memos go, no question asked. That is the case when you
  have answered once before, or when a directory in `~/dev/perso` carries
  exactly the cassette's name (a cassette called `life` needs no ceremony).
- **It does not** → the phone asks, once, which project folder it belongs
  in. The list comes *from* the laptop, and the phone hands back a name, not
  a path — the receiver would refuse anything it did not offer. Whatever
  already landed in the inbox meanwhile is **moved** into the chosen folder.
- **The laptop is asleep** → nothing is lost and nothing is asked: the tape
  is queued and files itself when the laptop answers again.

Answers live in `.routes.json` in the inbox; delete a line to be asked
again.

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
- a destination is chosen **by name from the laptop's own list**: the phone
  cannot name a directory the receiver did not offer;
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

## Two fork defaults

Both are upstream features (pull requests #35 and #36 on jaromiru/diktafon)
that this fork simply sets the other way:

- **Newest first.** A cassette's transcript reads latest memo at the top.
  Upstream ships tape order and offers the flip in the cassette's ⋮ menu;
  here every tape is one that gets added to and checked on, so the flip is
  the default and the menu entry turns it off. Memo numbers, the timeline
  and playback stay in tape order either way.
- **Progress in the notification.** The transcription progress the upstream
  change draws in the app is also written into the fork's foreground
  notification, since that is where you look when you are in another app.

## When something does not arrive

```bash
docker compose logs -f receiver                    # what the laptop sees
docker compose logs frpc                           # is the tunnel up
curl -u user:pass https://…/v1/ping -H "X-Diktafon-Token: …"
dart run tools/laptop-receiver/sync_probe.dart '<the pasted url>' probe
python3 tools/laptop-receiver/test_receiver.py     # the receiver's own tests
tools/laptop-receiver/pair-qr.sh                   # show the pairing code again
curl -u user:pass "https://…/v1/destination?label=life" -H "X-Diktafon-Token: …"
```

`sync_probe` sends a synthetic memo through the app's real client and payload
builder: if it arrives and the phone's do not, the problem is on the phone,
not in the tunnel.

`~/.local/bin/diktafon-pull` still works and needs none of this — it is the
fallback when the tunnel is down and the memo is needed now.
