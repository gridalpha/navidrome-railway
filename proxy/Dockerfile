# TLS-terminating edge for Navidrome.
#
# Navidrome trusts client-settable IP headers unconditionally (chi's RealIP
# middleware, no configuration), which on Railway makes its login rate limiter
# bypassable. This service normalises those headers before they reach it, and
# adds the HSTS header neither Navidrome nor Railway's edge emits.
FROM caddy:2-alpine

COPY Caddyfile /etc/caddy/Caddyfile

# Fail the build, not the boot, on a malformed config.
RUN caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

EXPOSE 8080
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
