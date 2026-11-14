# logseq-harbor

Containers for running Logseq's sync server, web app, and MCP server on your own machine.

| Service | Image | Port | What it does |
| --- | --- | --- | --- |
| `sync` | `localhost/logseq-sync` | 8787 | DB sync server (SQLite storage, filesystem assets) |
| `web` | `localhost/logseq-web` | 8080 | Logseq web app served by nginx |
| `mcp` | `localhost/logseq-mcp` | 12315 | Logseq desktop app under Xvfb, with its MCP HTTP server enabled |

The `mcp` service signs in to your Logseq account with credentials from `.env` and downloads one
sync graph (`LOGSEQ_GRAPH_NAME`) on first start. It then keeps that graph open, so MCP always has a
graph to work on. No GUI, VNC, or browser is needed.

## Prerequisites

- Podman (with `podman compose`, or `podman build` on Windows, see below)
- A checkout of the Logseq source tree next to this repo, as a sibling folder named `logseq`.
  The images are built from that folder. The `logseq` repo is never modified; the MCP image
  applies its small patches to a copy of the source at build time.
- A Logseq account that owns the sync graph you want MCP to use

## Configuration

Create a `.env` file next to `compose.yaml`. Do not commit it; `.gitignore` already excludes it.

```env
DB_SYNC_ADMIN_TOKEN=<random string>
LOGSEQ_MCP_TOKEN=<random string>
LOGSEQ_USERNAME=<your Logseq account email>
LOGSEQ_PASSWORD=<your Logseq account password>
LOGSEQ_GRAPH_NAME=<name of the sync graph to download>
# Optional, defaults to http://localhost:8787
DB_SYNC_BASE_URL=http://localhost:8787
```

Generate the two tokens with any secure random generator, for example
`python -c "import secrets; print(secrets.token_urlsafe(32))"`.

`LOGSEQ_PASSWORD` is stored in plain text in `.env` for now. Keep that file private.

## Build

From this folder:

```powershell
podman compose build
```

If the Compose provider on your machine does not support `additional_contexts` (it reports
"the classic builder doesn't support additional contexts"), build the MCP image directly. This
is the path used on Windows:

```powershell
cd mcp
podman build --network host --build-context logseq=../../logseq -t localhost/logseq-mcp:latest .
```

The MCP build is slow the first time. Dependency installs run before the source is copied, so
later source-only changes only rerun the compile steps.

## Run

```powershell
podman compose up -d
```

- Sync: `http://localhost:8787`
- Web app: `http://localhost:8080`
- MCP: `http://localhost:12315/mcp`, with `Authorization: Bearer <LOGSEQ_MCP_TOKEN>`

On first start, the `mcp` container signs in, downloads `LOGSEQ_GRAPH_NAME`, writes a marker file
(`.downloaded-<graph>`) in its data volume, and restarts the app with the graph open. Later starts
skip the download.

Check the MCP service:

```powershell
podman logs --tail 20 logseq-mcp
```

The endpoint returns `401` without the token and `200` with it.

## Persistence

| Volume | Holds |
| --- | --- |
| `logseq-db` | Sync server data (graphs, assets) |
| `mcp-data` | The MCP container's home folder: lifecycle state, downloaded graphs, and the download marker |

Removing containers keeps the data. Use `podman volume rm` only when you want to start over. Deleting
`mcp-data` makes the next start download the graph again.

## Troubleshooting

- **`Graph is absent or stopped by deletion`** in the MCP log: the local graph record is missing.
  The bootstrap creates it before the download. Check that `LOGSEQ_GRAPH_NAME` matches the graph name
  shown in the Logseq app.
- **`sign-in failed`**: check `LOGSEQ_USERNAME` and `LOGSEQ_PASSWORD` in `.env`. The account must not
  require MFA.
- **`Missing favorites page`** in the worker log: this is not fatal. Sync and API reads continue.
- **Sync websocket `ws-stale-timeout` warnings**: the client reconnects by itself.

## Layout

- `compose.yaml`: the three services and their volumes
- `sync/Dockerfile`, `web/Dockerfile`: sync and web images, built from the `logseq` source
- `mcp/Dockerfile`: builds the Electron app and creates the headless runtime image
- `mcp/patch-mcp-source.py`: build-time patches that enable env-based MCP config, the `/api`
  download route, and the snapshot-URL fix (the sync server returns `localhost` URLs)
- `mcp/bootstrap-graph.js`: headless sign-in and one-time graph download
- `mcp/entrypoint.sh`: starts the virtual display and keeps the app running with the graph open
