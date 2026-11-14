# Logseq DB sync server (db-sync node adapter) built from the local logseq source tree
# (the sibling logseq/ folder, passed as the build context).
#
# Based on the upstream image in yshalsager/logseq-selfhost (images/sync/Dockerfile),
# but using the same Debian bookworm base as the desktop image.
#
# Build (from E:\git\MCP\logseq-harbor\sync), source is ../logseq:
#   podman build --ignorefile Dockerfile.dockerignore --build-context logseq=../../logseq -f Dockerfile -t logseq-sync .
#
# --ignorefile is required: Podman does not pick up Dockerfile.dockerignore on its own.

ARG CLOJURE_IMAGE=clojure:temurin-21-tools-deps-bookworm-slim

FROM ${CLOJURE_IMAGE} AS build

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    python3 \
    make \
    g++ \
    && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable && corepack prepare pnpm@10.33.0 --activate

WORKDIR /src
# Only the folders db-sync compiles against (see deps/db-sync/deps.edn and shadow-cljs.edn).
COPY --from=logseq deps/common /src/deps/common
COPY --from=logseq deps/db /src/deps/db
COPY --from=logseq deps/outliner /src/deps/outliner
COPY --from=logseq deps/graph-parser /src/deps/graph-parser
COPY --from=logseq deps/db-sync /src/deps/db-sync
COPY --from=logseq resources /src/resources

# --ignore-workspace: deps/db-sync is self-contained and must not be hoisted into the
# root pnpm workspace.
WORKDIR /src/deps/db-sync
RUN pnpm install --frozen-lockfile --ignore-workspace \
    && pnpm run build:node-adapter \
    && CI=true pnpm prune --prod --ignore-workspace

FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get purge -y curl \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --no-create-home app

WORKDIR /app

COPY --chown=app:app --from=build /src/deps/db-sync/package.json /app/package.json
COPY --chown=app:app --from=build /src/deps/db-sync/node_modules /app/node_modules
COPY --chown=app:app --from=build /src/deps/db-sync/worker /app/worker

RUN mkdir -p /app/data && chown app:app /app/data

ENV DB_SYNC_PORT=8787
ENV DB_SYNC_DATA_DIR=/app/data
ENV DB_SYNC_STORAGE_DRIVER=sqlite
ENV DB_SYNC_ASSETS_DRIVER=filesystem

USER app
EXPOSE 8787

CMD ["node", "worker/dist/node-adapter.js"]
