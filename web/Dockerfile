# Logseq web app image built from the local logseq source tree (the sibling
# logseq/ folder, passed as the build context). Serves the static build with
# nginx, the same way as logseq/Dockerfile, but without cloning upstream.
#
# Mirrors `pnpm release` from logseq/package.json.
#
# Build (from E:\git\MCP\logseq-harbor\web), source is ../logseq:
#   podman build --build-context logseq=../../logseq -f Dockerfile -t localhost/logseq-web:latest .

ARG CLOJURE_IMAGE=clojure:temurin-21-tools-deps-bookworm-slim

FROM ${CLOJURE_IMAGE} AS builder

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
    xz-utils \
    libcairo2-dev libpango1.0-dev libjpeg-dev libgif-dev librsvg2-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable && corepack prepare pnpm@10.33.0 --activate

WORKDIR /src

# Point the web app's sync client at the local sync service (ws/http 127.0.0.1:8787) instead of
# api.logseq.io. Read at compile time by frontend.config/ENABLE-DB-SYNC-LOCAL in shadow-cljs.edn.
ENV ENABLE_DB_SYNC_LOCAL=true

# Only source trees are copied; build outputs and node_modules are regenerated.
COPY --from=logseq package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc \
    gulpfile.js webpack.config.js postcss.config.js tailwind.config.js \
    tailwind.all.css tailwind.mobile.css externs.js shadow-cljs.edn deps.edn ./
COPY --from=logseq src ./src
COPY --from=logseq deps ./deps
COPY --from=logseq libs ./libs
COPY --from=logseq resources ./resources
COPY --from=logseq public ./public
COPY --from=logseq scripts ./scripts
COPY --from=logseq assets ./assets
COPY --from=logseq icons ./icons
COPY --from=logseq static/package.json static/index.html static/404.html \
    static/marketplace.html static/icons.edn ./static/
COPY --from=logseq static/css ./static/css
COPY --from=logseq static/docs ./static/docs
COPY --from=logseq static/icons ./static/icons
COPY --from=logseq static/img ./static/img
COPY --from=logseq static/mobile ./static/mobile
COPY --from=logseq static/windows ./static/windows

RUN pnpm install --frozen-lockfile \
    && pnpm release

# Web app runner image
FROM nginx:1.24.0-alpine3.17

COPY --from=builder /src/static /usr/share/nginx/html
