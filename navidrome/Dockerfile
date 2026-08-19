# Navidrome for Railway.
#
# Upstream's image is a static Go binary on Alpine with ffmpeg. Everything added
# here exists because of a Railway constraint:
#
#   * Railway volumes are 1:1, and the image declares two (/data and /music), so
#     both are consolidated under a single /data mount.
#   * The image runs as root and Navidrome's own docs recommend against that, so
#     the entrypoint chowns the mount and drops to an unprivileged user. It needs
#     su-exec for that, which Alpine's busybox does not provide.
#   * A template deploy must not hand the first-admin screen to whoever reaches
#     the URL first, so the entrypoint creates the admin from variables through
#     Navidrome's own /auth/createAdmin route. That needs an HTTP client.
#   * ffmpeg sizes nothing from the cgroup, so the transcoding concurrency cap is
#     computed at boot from the container's real CPU quota.
FROM deluan/navidrome:latest

# curl   - first-admin bootstrap + demo library download
# jq     - builds the bootstrap JSON body, so a password holding a quote cannot
#          produce invalid JSON
# su-exec- privilege drop (busybox setpriv is capabilities-only on Alpine)
# tini   - reap the ffmpeg processes Navidrome spawns for transcoding
RUN apk add --no-cache curl jq su-exec tini

# The image bakes ND_MUSICFOLDER=/music and ND_DATAFOLDER=/data. A shell default
# in the entrypoint can never fire against a baked ENV, so re-declare them at the
# single mount point here; both stay overridable as service variables.
ENV ND_DATAFOLDER=/data \
    ND_MUSICFOLDER=/data/music \
    ND_CACHEFOLDER=/data/cache \
    ND_CONFIGFILE=/data/navidrome.toml \
    ND_ENFORCENONROOTUSER=true \
    ND_BACKUP_PATH=/data/backup \
    ND_BACKUP_SCHEDULE=@daily \
    ND_BACKUP_COUNT=7 \
    ND_SCANNER_SCHEDULE="@every 1h" \
    NAVIDROME_UID=1000 \
    NAVIDROME_GID=1000 \
    NAVIDROME_ADMIN_USERNAME=admin \
    NAVIDROME_DEMO_MUSIC=true

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Root at start so the entrypoint can chown the volume; it drops to
# NAVIDROME_UID before exec'ing Navidrome itself.
USER root
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
