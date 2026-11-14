# Logseq MCP image: the Linux Electron desktop app, run headless under Xvfb,
# with its MCP HTTP server enabled. Built from the local logseq source tree
# (the sibling logseq/ folder, passed as the build context).
#
# Mirrors the compile-cljs and build-linux-x64 jobs in
# logseq/.github/workflows/build-desktop-release.yml.
#
# Runtime env: LOGSEQ_MCP_ENABLED=true starts the MCP server on launch,
# LOGSEQ_MCP_HOST (default 127.0.0.1) and LOGSEQ_MCP_PORT (default 12315)
# control where it listens.
#
# Build (from E:\git\MCP\logseq-harbor\mcp), source is ../logseq:
#   podman build --build-context logseq=../../logseq -f Dockerfile -t localhost/logseq-mcp:latest .

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
    opam \
    libcairo2-dev libpango1.0-dev libjpeg-dev libgif-dev librsvg2-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable && corepack prepare pnpm@10.33.0 --activate

# OCaml toolchain for the bundled CLI (CI uses 5.1.1)
RUN opam init --disable-sandboxing --yes --bare \
    && opam switch create 5.1.1 --yes
ENV OPAMSWITCH=5.1.1

WORKDIR /src

# Installs run on manifests and lockfiles only, before the bulk source is copied. A source
# edit then reruns just the compile steps, not the dependency installs. pnpm copies local
# file: dependencies into node_modules during install, so deps/graph-lifecycle is copied whole.
COPY --from=logseq package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY --from=logseq deps/graph-lifecycle ./deps/graph-lifecycle
COPY --from=logseq cli/package.json cli/pnpm-lock.yaml cli/dune-project cli/logseq-cli.opam ./cli/
COPY --from=logseq static/package.json static/pnpm-lock.yaml ./static/
RUN pnpm install --frozen-lockfile \
    && pnpm --dir cli install --frozen-lockfile --ignore-workspace \
    && (cd cli && opam install . --deps-only --with-test --yes) \
    && (cd static && pnpm install --frozen-lockfile --ignore-workspace --config.node-linker=hoisted)

# Only source trees are copied; build outputs and node_modules are regenerated.
COPY --from=logseq gulpfile.js webpack.config.js postcss.config.js tailwind.config.js \
    tailwind.all.css tailwind.mobile.css externs.js shadow-cljs.edn deps.edn ./
COPY --from=logseq src ./src
COPY --from=logseq deps ./deps
COPY --from=logseq libs ./libs
COPY --from=logseq resources ./resources
COPY --from=logseq public ./public
COPY --from=logseq scripts ./scripts
COPY --from=logseq cli ./cli
COPY --from=logseq bin ./bin
COPY --from=logseq assets ./assets
COPY --from=logseq icons ./icons
COPY --from=logseq sidecar ./sidecar
COPY --from=logseq .agents ./.agents
COPY --from=logseq static/electron-builder.yml \
    static/electron.js static/entitlements.plist static/forge.config.test.js \
    static/icon.png static/icon_monochrome.png static/icons.edn static/index.html \
    static/marketplace.html static/404.html static/tests.js static/db-worker-node.js ./static/
COPY --from=logseq static/css ./static/css
COPY --from=logseq static/docs ./static/docs
COPY --from=logseq static/icons ./static/icons
COPY --from=logseq static/img ./static/img
COPY --from=logseq static/mobile ./static/mobile
COPY --from=logseq static/windows ./static/windows

# Runtime env support (LOGSEQ_MCP_ENABLED/HOST/PORT/TOKEN) and localhost host allowlist.
# Patches the copied source only; the logseq repo is not modified. Fails if the source changed.
COPY patch-mcp-source.py /tmp/patch-mcp-source.py
RUN python3 /tmp/patch-mcp-source.py .

# compile-cljs job
# Compile-time flag that enables the db-sync UI and the sync server URL setting.
ENV ENABLE_DB_SYNC_LOCAL=true
RUN pnpm exec gulp build \
    && pnpm cljs:release-electron \
    && pnpm db-worker-node:bundle \
    && opam exec -- pnpm cli:release \
    && pnpm webpack-app-build \
    && pnpm desktop:prepare-runtime-js

# build-linux-x64 job
WORKDIR /src/static
# electron-builder collects prod deps via `pnpm list`, which returns an empty tree when static/
# sits under the root workspace. A local pnpm-workspace.yaml makes static/ its own root.
RUN printf 'packages: []\n' > pnpm-workspace.yaml && pnpm electron:make \
    && test -f dist/linux-unpacked/resources/sidecar/embedding_server.py

# Runtime: the packaged app needs a display, so it runs under Xvfb.
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb \
    xauth \
    dbus-x11 \
    ca-certificates \
    fonts-liberation \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcairo2 \
    libcups2 \
    libdrm2 \
    libgbm1 \
    libgtk-3-0 \
    libnss3 \
    libsecret-1-0 \
    libpango-1.0-0 \
    libxcomposite1 \
    libxdamage1 \
    libxkbcommon0 \
    libxrandr2 \
    libxshmfence1 \
    libxss1 \
    libxtst6 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/static/dist/linux-unpacked /opt/logseq

WORKDIR /opt/logseq

COPY bootstrap-graph.js entrypoint.sh /opt/harbor/
RUN sed -i 's/\r$//' /opt/harbor/entrypoint.sh && chmod +x /opt/harbor/entrypoint.sh

ENV LOGSEQ_MCP_ENABLED=true \
    LOGSEQ_MCP_HOST=0.0.0.0 \
    LOGSEQ_MCP_PORT=12315

EXPOSE 12315

# Chromium refuses to start as root without --no-sandbox; this container runs as root.
# The entrypoint signs in, downloads LOGSEQ_GRAPH_NAME, and keeps the app open on it.
ENTRYPOINT ["/opt/harbor/entrypoint.sh"]
