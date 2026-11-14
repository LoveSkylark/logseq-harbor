# logseq-harbor

Containers for running Logseq's sync server, web app, and MCP server on your own machine.

| Service | Image | Port | What it does |
| --- | --- | --- | --- |
| `sync` | `localhost/logseq-sync` | 8787 | DB sync server (SQLite storage, filesystem assets) |
| `web` | `localhost/logseq-web` | 8080 | Logseq web app served by nginx |
| `mcp` | `localhost/logseq-mcp` | 12315+ | Logseq desktop app under Xvfb, with its MCP HTTP server enabled; one container per graph |

The `mcp` service signs in to your Logseq account with credentials from `config.yaml` and downloads one
sync graph on first start. It then keeps that graph open, so MCP always has a graph to work on. No GUI,
VNC, or browser is needed.

`harbor.ps1` (Windows) and `harbor.sh` (Linux) start the stack. They start sync, optionally web, and one
MCP container per graph listed in `config.yaml`. Each graph's files are also mounted on the host.

## Prerequisites

- Podman. The scripts call the `podman` CLI; set `HARBOR_RUNTIME_ARGS` if you use a remote machine
  (on Windows the default is `--remote --connection podman-machine-default-root`).
- A checkout of the Logseq source tree next to this repo, as a sibling folder named `logseq`.
  The images are built from that folder. The `logseq` repo is never modified; the MCP image
  applies its small patches to a copy of the source at build time.
- A Logseq account that owns the sync graphs you want MCP to use

## Configuration

Create `config.yaml` next to the scripts. Do not commit it; `.gitignore` already excludes it.

```yaml
graphs:
  - my-graph
  - another-graph
web: true
graphs_dir: ~/logseq-harbor/graphs
db_sync_admin_token: <random string>
logseq_mcp_token: <random string>
logseq_username: <your Logseq account email>
logseq_password: <your Logseq account password>
# Optional, defaults to http://localhost:8787
# db_sync_base_url: http://localhost:8787
```

- `graphs`: one MCP container starts per entry. Ports are assigned in order from 12315 (12315, 12316, ...).
- `web`: `true` starts the web app on port 8080; `false` skips it.
- `graphs_dir`: host folder for the graph files. Each graph is mounted at `<graphs_dir>/<graph>`.
  `~` means your home folder.
- `sync_data_dir`: optional host folder for the sync server's data (`index.sqlite`, assets, graphs). Defaults to
  `~/logseq-harbor/sync-data`. It holds the account encryption key, so back it up.

Only use plain `key: value` pairs and the `graphs:` list. Do not add inline comments after values.
Values can be set in the environment instead, which overrides `config.yaml` (for example
`LOGSEQ_PASSWORD`). Generate the two tokens with any secure random generator, for example
`python -c "import secrets; print(secrets.token_urlsafe(32))"`.

`logseq_password` is stored in plain text in `config.yaml` for now. Keep that file private.

## Build

From this folder, build the three images once (and again after changes to `logseq`, `sync`, `web` or `mcp`):

```powershell
.\harbor.ps1 build
```

```bash
./harbor.sh build
```

The MCP build is slow the first time. Dependency installs run before the source is copied, so
later source-only changes only rerun the compile steps.

## Run

```powershell
.\harbor.ps1 up        # or: ./harbor.sh up
.\harbor.ps1 status    # list the containers
.\harbor.ps1 stop      # remove the containers (data volumes are kept)
```

- Sync: `http://localhost:8787`
- Web app (when `web: true`): `http://localhost:8080`
- MCP, one per graph: `http://localhost:12315/mcp`, `12316`, ... in the order listed in `config.yaml`,
  with `Authorization: Bearer <logseq_mcp_token>`

On first start, each MCP container signs in, downloads its graph into `<graphs_dir>/<graph>`, writes a
marker file (`.downloaded-<graph>`) in its data volume, and restarts the app with the graph open. Later
starts skip the download.

Check an MCP container:

```powershell
podman logs --tail 20 logseq-mcp-<graph>
```

The endpoint returns `401` without the token and `200` with it.

## Persistence

| Volume or folder | Holds |
| --- | --- |
| `<sync_data_dir>` (host, default `~/logseq-harbor/sync-data`) | Sync server data: `index.sqlite` with the account key, graphs, assets |
| `mcp-data-<graph>` | Each MCP container's home folder: lifecycle state and the download marker |
| `<graphs_dir>/<graph>` (host) | The graph's files, mounted into the MCP container |

Removing containers keeps the data. Use `podman volume rm` only when you want to start over. Deleting
`mcp-data-<graph>` makes the next start download that graph again.

## Troubleshooting

- **`Graph is absent or stopped by deletion`** in the MCP log: the local graph record is missing.
  The bootstrap creates it before the download. Check that the name under `graphs:` matches the graph
  name shown in the Logseq app.
- **`sign-in failed`**: check `logseq_username` and `logseq_password` in `config.yaml`. The account must not
  require MFA.
- **`Missing favorites page`** in the worker log: this is not fatal. Sync and API reads continue.
- **Sync websocket `ws-stale-timeout` warnings**: the client reconnects by itself.

## Layout

- `harbor.ps1`, `harbor.sh`: build and run the stack (PowerShell and bash)
- `config.yaml`: your graphs, web switch, host graph folder and credentials (git-ignored)
- `sync/Dockerfile`, `web/Dockerfile`: sync and web images, built from the `logseq` source
- `mcp/Dockerfile`: builds the Electron app and creates the headless runtime image
- `mcp/patch-mcp-source.py`: build-time patches that enable env-based MCP config, the `/api`
  download route, and the snapshot-URL fix (the sync server returns `localhost` URLs)
- `mcp/bootstrap-graph.js`: headless sign-in and one-time graph download
- `mcp/entrypoint.sh`: starts the virtual display and keeps the app running with the graph open
