---
description: Security posture of the SillyTavern Docker image: shipped auth defaults, what to change before exposing it, and the non-root, credential-guard, and digest-pin hardening applied here.
tags: [docker, security, deployment, hardening]
date: 2026-07-09
---

# DOCKER SECURITY NOTES

scope = the image built from the repo-root `Dockerfile`. read before publishing port 8000 anywhere but localhost.

## SHIPPED DEFAULTS: NO AUTHENTICATION

`docker-entrypoint.sh` starts `node server.js --listen`, so the server binds `0.0.0.0:8000`. authentication is OFF. an IP allowlist is the only gate.

- `basicAuthMode: false` (`default/config.yaml:70`). the `basicAuthUser` pair `user` / `password` (:72) sits unused, NOT a live credential.
- `enableUserAccounts: false` (:107), `enableDiscreetLogin: false` (:109).
- `whitelistMode: true` (:60) w/ `whitelist: [::1, 127.0.0.1]` (:64).
- `whitelistDockerHosts: true` (:68) auto-allows the docker host + gateway IPs.
- `enableForwardedWhitelist: true` (:62) takes the client IP from `forwardedHeaders`.
- `sessionTimeout: -1` (:178) = sessions never expire.

consequence: publish 8000 to a LAN or the internet and every allowlisted IP gets an unauthenticated UI. behind a reverse proxy the proxy's own IP is what the allowlist checks, and a client-supplied forwarded header can pass it.

## BEFORE EXPOSING / MULTI-USER

edit the MOUNTED `config/config.yaml`, not `default/config.yaml`:

- turn on auth: `basicAuthMode: true` + replace both `basicAuthUser` values, OR `enableUserAccounts: true`.
- `sessionTimeout` -> positive value.
- keep `whitelistMode: true`; add only the client IPs you mean to allow.
- `enableForwardedWhitelist: true` is safe ONLY when every hop in front is trusted and overwrites the forwarded header. untrusted hop -> a client picks its own source IP.
- terminate TLS upstream, or set `ssl` in config. the image serves plain HTTP.

## HARDENING APPLIED

### NON-ROOT BY DEFAULT

`docker-entrypoint.sh` drops privileges to the `node` user (uid 1000) via `su-exec` in every mode. `tini` remains PID 1 as root for signal handling; the node process never runs as root.

- default, no vars: chown core dirs to `node`, then drop.
- `PUID` / `PGID` set: remap `node` to those ids, chown core dirs, then drop.
- `docker run --user`: already non-root, no chown possible, nothing to drop.

no Dockerfile `USER` directive on purpose. the entrypoint needs root to `usermod` for PUID/PGID and to chown bind mounts. `USER node` would make `id -u` nonzero at entry and disable both paths, so the drop happens in the entrypoint instead (`Dockerfile:53`).

### CREDENTIAL LEAK GUARD

`.dockerignore` excludes root `config.yaml`, `config.conf`, `config.conf.bak`, and `config/`.

`Dockerfile:19` runs `COPY --chown=node:node . ./`. without those excludes, a local `docker build` from a tree that has ever run SillyTavern natively bakes the live `basicAuthUser` credentials into an image layer. the later `rm -f config.yaml` (`Dockerfile:28`) does NOT undo that; the file survives in layer history. `default/config.yaml` stays copied, the build needs it.

### BASE IMAGE DIGEST PIN

`Dockerfile:2` pins `node:lts-alpine3.23@sha256:595398b0...`, the multi-arch OCI index digest, so amd64 / arm64 / s390x all still resolve. the bare tag is mutable and moves on every upstream node release.

re-pin deliberately (the index digest, NOT a per-platform one):

```sh
docker buildx imagetools inspect node:lts-alpine3.23 --format '{{println .Manifest.Digest}}'
```

bump tag and digest together, and rebuild to pick up base-image CVE fixes; a pin freezes those too.
