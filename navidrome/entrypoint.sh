#!/bin/sh
# Navidrome on Railway — boot-time work the published image cannot do itself.
set -eu

log() { echo "[entrypoint] $*"; }

# ---------------------------------------------------------------- port ------
# Navidrome binds the bare PORT variable as well, but the image bakes ND_PORT
# and viper checks the prefixed name first — so Railway's PORT would be ignored
# unless it is promoted here.
if [ -n "${PORT:-}" ]; then
    ND_PORT="$PORT"
    export ND_PORT
fi
: "${ND_PORT:=4533}"

DATA="${ND_DATAFOLDER:-/data}"
MUSIC="${ND_MUSICFOLDER:-$DATA/music}"
CACHE="${ND_CACHEFOLDER:-$DATA/cache}"
BACKUP="${ND_BACKUP_PATH:-$DATA/backup}"
RUN_UID="${NAVIDROME_UID:-1000}"
RUN_GID="${NAVIDROME_GID:-1000}"

mkdir -p "$DATA" "$MUSIC" "$CACHE" "$BACKUP"

# ------------------------------------------------- transcoding capacity -----
# ffmpeg derives nothing from the cgroup and Railway's hosts are much larger
# than the container's quota, so cap concurrent transcodes at the real quota.
if [ -z "${ND_TRANSCODING_MAXCONCURRENT:-}" ] && [ -r /sys/fs/cgroup/cpu.max ]; then
    quota=$(awk '{print $1}' /sys/fs/cgroup/cpu.max)
    period=$(awk '{print $2}' /sys/fs/cgroup/cpu.max)
    if [ "$quota" != "max" ] && [ -n "${period:-}" ] && [ "$period" -gt 0 ] 2>/dev/null; then
        cpus=$((quota / period))
        [ "$cpus" -lt 1 ] && cpus=1
        ND_TRANSCODING_MAXCONCURRENT="$cpus"
        export ND_TRANSCODING_MAXCONCURRENT
        log "transcoding.maxconcurrent=$cpus (from cgroup cpu quota; host reports $(nproc) cores)"
    fi
fi

# ------------------------------------------------------- demo library ------
# A music server with no music cannot be verified, and a fresh template deploy
# would otherwise open on an empty page. Seeds a handful of public-domain and
# CC0 recordings, only while the library is empty, and never fatally.
DEMO_VERSION=2
seed_demo_music() {
    [ "${NAVIDROME_DEMO_MUSIC:-false}" = "true" ] || return 0

    # The marker records the demo version and every directory this function
    # created, so a later version can replace its own content and nothing else.
    # A library the operator filled has no marker and is never touched.
    _marker="$MUSIC/.railway-demo"
    _demo_dirs="Frédéric Chopin
Franz Schubert
Sergei Rachmaninoff"

    if [ -f "$_marker" ] && [ "$(head -n 1 "$_marker")" = "$DEMO_VERSION" ]; then
        log "demo library skipped: already seeded at version $DEMO_VERSION"
        return 0
    fi

    if [ -f "$_marker" ]; then
        # Our own seed, one version behind: replace exactly what it recorded.
        log "demo library: replacing version $(head -n 1 "$_marker") with $DEMO_VERSION"
        tail -n +2 "$_marker" | while IFS= read -r _old; do
            [ -n "$_old" ] && [ -d "$MUSIC/$_old" ] && rm -rf "$MUSIC/$_old"
        done
        rm -f "$_marker"
    elif [ -n "$(ls -A "$MUSIC" 2>/dev/null || true)" ]; then
        # No marker. Either a library the operator filled — which must never be
        # touched — or a demo seeded before the marker existed. Only the second
        # can consist solely of the directories this function creates.
        _foreign=0
        _entries=$(ls -A "$MUSIC" 2>/dev/null || true)
        _oldifs=$IFS
        IFS='
'
        set -f
        for _entry in $_entries; do
            printf '%s\n' "$_demo_dirs" | grep -qxF "$_entry" || _foreign=1
        done
        set +f
        IFS=$_oldifs
        if [ "$_foreign" = "1" ]; then
            log "demo library skipped: $MUSIC holds files this seeder did not write"
            return 0
        fi
        log "demo library: replacing an unversioned demo library with version $DEMO_VERSION"
        printf '%s\n' "$_demo_dirs" | while IFS= read -r _old; do
            [ -d "$MUSIC/$_old" ] && rm -rf "$MUSIC/$_old"
        done
    fi

    log "seeding demo library into $MUSIC (public-domain / CC0 recordings)"
    tmp=$(mktemp -d)
    mkdir -p "$MUSIC"

    # add_track <url> <artist> <album> <track> <title> <year> <filename>
    add_track() {
        _url="$1"; _artist="$2"; _album="$3"; _track="$4"; _title="$5"; _year="$6"; _file="$7"
        _dir="$MUSIC/$(echo "$_artist" | tr -d '/')/$(echo "$_album" | tr -d '/')"
        mkdir -p "$_dir"
        if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 60 -o "$tmp/track.ogg" "$_url"; then
            log "demo library: download failed for $_title"
            return 1
        fi
        # An Ogg carries its tags in the audio stream's Vorbis comment header,
        # and `-c copy` carries that header across verbatim — so a source file
        # that arrives already tagged keeps its own album and artist and ignores
        # every -metadata flag. Drop both metadata scopes first, then write both.
        set -- -map_metadata -1 -map_metadata:s:a:0 -1
        for _scope in "" ":s:a:0"; do
            set -- "$@" \
                -metadata${_scope} ARTIST="$_artist" \
                -metadata${_scope} ALBUMARTIST="$_artist" \
                -metadata${_scope} ALBUM="$_album" \
                -metadata${_scope} TITLE="$_title" \
                -metadata${_scope} TRACKNUMBER="$_track" \
                -metadata${_scope} DATE="$_year" \
                -metadata${_scope} GENRE="Classical" \
                -metadata${_scope} COMMENT="Public-domain recording from Wikimedia Commons"
        done
        ffmpeg -nostdin -loglevel error -y -i "$tmp/track.ogg" -c copy "$@" \
            "$_dir/$_track - $_file.ogg" \
            || { log "demo library: tagging failed for $_title"; return 1; }
        log "demo library: added $_artist - $_title"
    }

    add_cover() {
        _artist="$1"; _album="$2"; _url="$3"
        _dir="$MUSIC/$_artist/$_album"
        [ -d "$_dir" ] || return 0
        curl -fsSL --retry 2 --max-time 30 -o "$_dir/cover.jpg" "$_url" \
            || log "demo library: cover download failed for $_album"
    }

    CHA="Piano Works"
    add_track "https://upload.wikimedia.org/wikipedia/commons/9/9f/Chopin_-_Waltz_op._34_no_3.ogg" \
        "Frédéric Chopin" "$CHA" "01" "Waltz in F major, Op. 34 No. 3" "1838" "Waltz Op 34 No 3" || true
    add_track "https://upload.wikimedia.org/wikipedia/commons/e/ea/Chopin_-_Polonaise-op-26-no-2.ogg" \
        "Frédéric Chopin" "$CHA" "02" "Polonaise in E-flat minor, Op. 26 No. 2" "1836" "Polonaise Op 26 No 2" || true
    add_track "https://upload.wikimedia.org/wikipedia/commons/3/30/Chopin_-_Scherzo_No._3.ogg" \
        "Frédéric Chopin" "$CHA" "03" "Scherzo No. 3 in C-sharp minor, Op. 39" "1839" "Scherzo No 3" || true
    add_track "https://upload.wikimedia.org/wikipedia/commons/a/ab/Franz_Schubert%2C_Impromptu_Opus_post._D_946_-_No._3_in_C_major_%28Allegro%29.ogg" \
        "Franz Schubert" "Drei Klavierstücke" "01" "Impromptu in C major, D. 946 No. 3" "1828" "Impromptu D 946 No 3" || true
    add_track "https://upload.wikimedia.org/wikipedia/commons/8/8a/Sergei_Rachmaninoff_-_Etudes-Tableaux%2C_Op._39%2C_No._5.oga" \
        "Sergei Rachmaninoff" "Études-Tableaux" "01" "Étude-Tableau in E-flat minor, Op. 39 No. 5" "1917" "Etude Tableau Op 39 No 5" || true

    add_cover "Frédéric Chopin" "$CHA" \
        "https://upload.wikimedia.org/wikipedia/commons/9/9a/Eug%C3%A8ne_Delacroix_-_Fr%C3%A9d%C3%A9ric_Chopin_-_WGA06194.jpg"
    add_cover "Franz Schubert" "Drei Klavierstücke" \
        "https://upload.wikimedia.org/wikipedia/commons/thumb/0/0d/Franz_Schubert_by_Wilhelm_August_Rieder_1875.jpg/960px-Franz_Schubert_by_Wilhelm_August_Rieder_1875.jpg"
    add_cover "Sergei Rachmaninoff" "Études-Tableaux" \
        "https://upload.wikimedia.org/wikipedia/commons/thumb/b/be/Sergei_Rachmaninoff_cph.3a40575.jpg/960px-Sergei_Rachmaninoff_cph.3a40575.jpg"

    rm -rf "$tmp"
    { printf '%s\n' "$DEMO_VERSION"; printf '%s\n' "$_demo_dirs"; } > "$_marker"
    log "demo library seeded: $(find "$MUSIC" -name '*.ogg' | wc -l) tracks (version $DEMO_VERSION)"
}
seed_demo_music || log "demo library seeding failed; continuing with an empty library"

# ---------------------------------------------------------- ownership ------
# Railway mounts the volume as root. Navidrome refuses to run as root
# (ND_ENFORCENONROOTUSER), so hand the whole mount to the runtime user.
if ! getent group "$RUN_GID" >/dev/null 2>&1; then
    addgroup -g "$RUN_GID" navidrome
fi
if ! getent passwd "$RUN_UID" >/dev/null 2>&1; then
    adduser -D -H -u "$RUN_UID" -G "$(getent group "$RUN_GID" | cut -d: -f1)" -s /bin/sh navidrome
fi
chown "$RUN_UID:$RUN_GID" "$DATA" "$MUSIC" "$CACHE" "$BACKUP"
# The database, cache and backups are small. The music tree is not: a real
# library is hundreds of gigabytes, so walking it on every boot would add
# minutes to every deploy. Claim it once — files uploaded to the volume later
# arrive world-readable, and Navidrome only ever reads them.
for _d in "$DATA"/*; do
    [ "$_d" = "$MUSIC" ] && continue
    [ -e "$_d" ] || continue
    chown -R "$RUN_UID:$RUN_GID" "$_d" || true
done
if [ ! -e "$DATA/.railway-music-owned" ]; then
    chown -R "$RUN_UID:$RUN_GID" "$MUSIC" || true
    : > "$DATA/.railway-music-owned"
    chown "$RUN_UID:$RUN_GID" "$DATA/.railway-music-owned"
fi

# su-exec preserves the environment, so HOME would still be /root and anything
# looking for a dotfile there would be denied.
HOME="$DATA"
export HOME

# ------------------------------------------------- first admin bootstrap ----
# Navidrome has no public sign-up: the first account is created from the
# first-run screen, which on a public URL is claimable by whoever finds it
# first. /auth/createAdmin is the route that screen posts to, and it answers 403
# once any user exists — so this runs once and is a no-op on every later boot.
bootstrap_admin() {
    _user="${NAVIDROME_ADMIN_USERNAME:-admin}"
    _pass="${NAVIDROME_ADMIN_PASSWORD:-}"
    if [ -z "$_pass" ]; then
        log "NAVIDROME_ADMIN_PASSWORD is unset — leaving the first-run screen open."
        log "WARNING: anyone reaching this URL can claim the instance until an admin exists."
        return 0
    fi
    _i=0
    while [ "$_i" -lt 90 ]; do
        if curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${ND_PORT}/ping"; then break; fi
        _i=$((_i + 1)); sleep 2
    done
    if [ "$_i" -ge 90 ]; then
        log "admin bootstrap: server did not answer /ping in time"
        return 0
    fi
    _body=$(jq -n --arg u "$_user" --arg p "$_pass" '{username:$u,password:$p}')
    _code=$(printf '%s' "$_body" | curl -s -o /tmp/createadmin.out -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' --data-binary @- \
        "http://127.0.0.1:${ND_PORT}/auth/createAdmin" || echo 000)
    case "$_code" in
        200) log "admin bootstrap: created initial admin user '$_user'" ;;
        403) log "admin bootstrap: a user already exists, nothing to do" ;;
        *)   log "admin bootstrap: failed with HTTP $_code — $(head -c 200 /tmp/createadmin.out 2>/dev/null)" ;;
    esac
    rm -f /tmp/createadmin.out
}
bootstrap_admin &

# The bootstrap subshell forked with its own copy, so the running server never
# sees the password in its environment.
unset NAVIDROME_ADMIN_PASSWORD

log "starting navidrome as uid=$RUN_UID gid=$RUN_GID on port $ND_PORT"
exec su-exec "$RUN_UID:$RUN_GID" /app/navidrome "$@"
