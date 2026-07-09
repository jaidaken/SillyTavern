# Digest pins the multi-arch index, not one platform; bump tag and digest together.
FROM node:lts-alpine3.23@sha256:595398b0081eacda8e1c4c5b97b76cd1020e4d58a8ebcb4843b9bca1e79e7436

# Arguments
ARG APP_HOME=/home/node/app

# Install system dependencies
# "Don't rely on the base image for tools; if you call it, you install it." ;)
RUN apk add --no-cache gcompat tini git git-lfs su-exec shadow dos2unix

# Create app directory and set ownership
WORKDIR ${APP_HOME}
RUN chown node:node ${APP_HOME}

# Set NODE_ENV to production
ENV NODE_ENV=production

# Bundle app source and set ownership
COPY --chown=node:node . ./

RUN \
  echo "*** Install npm packages ***" && \
  npm ci --no-audit --no-fund --loglevel=error --no-progress --omit=dev --ignore-scripts && npm cache clean --force

# Create config directory and link config.yaml. Added hardcoded dirs(constants.js?)
# that must be present for Non-Root Mode and volumeless docker runs.
RUN \
  rm -f "config.yaml" || true && \
  mkdir -p config data plugins public/scripts/extensions/third-party backups && \
  chown -R node:node config data plugins public/scripts/extensions/third-party backups && \
  ln -s "./config/config.yaml" "config.yaml"

# Pre-compile public libraries
RUN \
  echo "*** Run Webpack ***" && \
  node "./docker/build-lib.js"

# Set the entrypoint script and cleanup
RUN \
  echo "*** Cleanup ***" && \
  mv "./docker/docker-entrypoint.sh" "./" && \
  echo "*** Make docker-entrypoint.sh executable ***" && \
  chmod +x "./docker-entrypoint.sh" && \
  echo "*** Convert line endings to Unix format ***" && \
  dos2unix "./docker-entrypoint.sh" && \
  rm -rf "./docker"

# Fix extension repos permissions
RUN git config --global --add safe.directory "*"

EXPOSE 8000

# No USER directive: the entrypoint needs root to chown mounted volumes, then drops to 'node' via su-exec.
# Ensure proper handling of kernel signals
ENTRYPOINT ["tini", "--", "./docker-entrypoint.sh"]
