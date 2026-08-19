# navidrome-railway

Deployment repo for running [Navidrome](https://github.com/navidrome/navidrome)
on [Railway](https://railway.com) — a self-hosted music streamer for your own
library, with a Subsonic-compatible API that every Subsonic client app speaks.

Two services build from this repo:

| Directory | Service | Public | What it is |
|---|---|---|---|
| `navidrome/` | `navidrome` | no | Upstream's image plus one entrypoint |
| `proxy/` | `proxy` | yes | Caddy, normalising client-IP headers and adding HSTS |

## Why the app image is wrapped

Everything in `navidrome/` exists because of a Railway constraint, not a
preference:

- **One volume.** The image declares `/data` *and* `/music`; Railway volumes are
  1:1, so both live under a single `/data` mount and the paths are re-declared in
  the Dockerfile. A shell default can never override a baked `ENV`.
- **Non-root.** The image runs as root and Navidrome's own documentation advises
  against it. The entrypoint chowns the mount, then drops to `NAVIDROME_UID`
  through `su-exec`, with `ND_ENFORCENONROOTUSER=true` so a failed drop is loud
  rather than silent. The music tree is claimed only on first boot — a real
  library is far too large to walk on every deploy.
- **First admin.** Navidrome has no sign-up: the first account is created from
  the first-run screen, which on a public URL belongs to whoever finds it first.
  The entrypoint posts to `/auth/createAdmin`, the same route that screen uses.
  It answers 403 once any user exists, so later boots do nothing.
- **`PORT`.** Navidrome binds the bare `PORT` variable, but the image bakes
  `ND_PORT`, which viper resolves first — so Railway's `PORT` is promoted
  explicitly.
- **Transcoding capacity.** ffmpeg derives nothing from the cgroup, so the
  concurrency cap is computed at boot from the container's real CPU quota.

## Why the proxy exists

Navidrome resolves the client address with chi's `RealIP` middleware, which
takes `True-Client-IP`, then `X-Real-IP`, then the leftmost `X-Forwarded-For` —
with no configuration and no way to disable it. Railway's edge overwrites only
`X-Forwarded-For`, so on a bare deployment any client can pick its own address
and the login rate limiter (`ND_AUTHREQUESTLIMIT`, 5 per 20 s by default) is
bypassable a request at a time. The proxy deletes `True-Client-IP` and sets
`X-Real-IP` from the leftmost forwarded entry, which is the real client because
the edge overwrites what the client sent.

It also adds `Strict-Transport-Security`, which Navidrome cannot emit and
Railway's edge does not add, and keeps Navidrome itself off the public internet.

## Variables

Set on `navidrome`:

| Variable | Default | Purpose |
|---|---|---|
| `NAVIDROME_ADMIN_PASSWORD` | — | Password for the first admin. Unset leaves the first-run screen open to anyone. |
| `NAVIDROME_ADMIN_USERNAME` | `admin` | |
| `ND_PASSWORDENCRYPTIONKEY` | — | Encrypts stored credentials. **Never change it after first boot** — Navidrome decrypts user passwords with it. |
| `PORT` | `4533` | |
| `NAVIDROME_DEMO_MUSIC` | `true` | Seeds five public-domain recordings when the library is empty, so a fresh deployment is not a blank page. |
| `NAVIDROME_UID` / `NAVIDROME_GID` | `1000` | |
| `ND_SCANNER_SCHEDULE` | `@every 1h` | Uploads made to the volume from outside the container do not raise a filesystem event, so the periodic scan is what finds them. |
| `ND_BACKUP_PATH` / `_SCHEDULE` / `_COUNT` | `/data/backup`, `@daily`, `7` | Navidrome's own SQLite backups. |

Set on `proxy`:

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `8080` | |
| `NAVIDROME_UPSTREAM` | `navidrome.railway.internal:4533` | Defaulted in the Caddyfile, so the template needs no host variable. |

Every other `ND_*` option from
[Navidrome's configuration reference](https://www.navidrome.org/docs/usage/configuration-options/)
works as a service variable.

## Adding your own music

Navidrome indexes files; it has no upload UI. Put music on the volume with:

```
railway volume files upload ./album --volume navidrome-data /music/
```

then wait for the next scheduled scan, or trigger one from
Settings → About → Quick Scan.

## Demo library

Seeded only while the library is empty, from Wikimedia Commons:

| Recording | Licence |
|---|---|
| Chopin — Waltz Op. 34 No. 3 | CC0 |
| Chopin — Polonaise Op. 26 No. 2 | CC0 |
| Chopin — Scherzo No. 3, Op. 39 | Public domain |
| Schubert — Impromptu D. 946 No. 3 | CC0 |
| Rachmaninoff — Étude-Tableau Op. 39 No. 5 | Public domain |

Cover art is the Delacroix portrait of Chopin, Rieder's portrait of Schubert and
a Library of Congress photograph of Rachmaninoff — all public domain.

Set `NAVIDROME_DEMO_MUSIC=false` to skip it, and delete `/data/music/*` to
remove it after the fact.
