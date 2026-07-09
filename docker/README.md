# docker/

Build and runtime assets for the SillyTavern container image. The image is built from the repo-root `Dockerfile`, which uses this directory during the build and then removes it from the final image.

- [Security notes](SECURITY-NOTES.md) - shipped auth defaults, what to change before exposing the container, and the non-root / digest-pin hardening.

Contents:

- `docker-compose.yml` - reference compose file (build context is the repo root).
- `docker-entrypoint.sh` - entrypoint; creates required directories, fixes ownership, drops privileges to `node`, starts the server.
- `build-lib.js` - webpack step that pre-compiles `public/lib.js` during the image build.
