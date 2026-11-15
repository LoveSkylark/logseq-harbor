# Harbor multi-graph setup

Read this when the MCP server is run by logseq-harbor and more than one graph is
available. It explains which graph a tool call reaches and how to avoid mixing
graphs.

## How Harbor runs graphs

- `config.yaml` lists the sync graphs under `graphs:`. Each graph gets its own
  MCP container, named `logseq-mcp-<slug>`, and its own host port, starting at
  12315 and counting up. The slug keeps letters, digits, `_` and `-`; each run
  of other characters becomes `-`, and leading and trailing `-` are trimmed.
- Each container opens exactly one graph. A call to a container reads or writes
  only that graph. There is no tool that spans graphs.
- A container never creates a graph. It downloads a graph that already exists in
  the sync server, so the graph must exist there first.
- Every MCP container uses the same bearer token, `logseq_mcp_token`, from
  `config.yaml`. Never print or paste it.

## Entry points

| Path | Purpose | Auth |
| --- | --- | --- |
| `http://localhost:8080/` | Web app | none |
| `http://localhost:8080/sync` | Sync server (redirects to `/sync/`) | user login |
| `http://localhost:8080/mcp` | JSON list of running graphs | none |
| `http://localhost:8080/mcp/<route>` | MCP server for one graph | `Authorization: Bearer <token>` |

The proxy is `logseq-proxy`, published on port 8080. Each `/mcp` entry has:
`graph` (the name as shown in Logseq), `route` (the path segment), and `url`.

Route rule: lowercase the graph name and replace each run of characters that are
not `a-z` or `0-9` with `-`, then trim the `-` at both ends. For example,
`Campaign - 7th Trial` becomes `campaign-7th-trial`. Routes are case-sensitive,
so `/mcp/Personal` returns 404; use `/mcp/personal`.

Each graph is also reachable directly on its own port, `http://localhost:<port>/mcp`,
with the same bearer token. Use the port that `harbor.ps1 status` prints.

## Clients

- **Single graph:** point the client at `http://localhost:8080/mcp/<route>`, or
  at the graph's direct port.
- **Several graphs:** the Logseq Harbor Connect Claude Desktop extension reads
  `/mcp`, connects to each graph's `url`, and exposes every tool with the graph
  slug as a prefix, for example `Personal__findEntities`. Its tool descriptions
  start with `[Graph: <name>]`. The prefix is the graph name with runs of
  non-alphanumeric characters turned into `-`, so `Work - Sensa` becomes
  `Work-Sensa`. A graph that fails to connect is skipped and the rest keep
  working.

## Rules for working across graphs

- Before any task, identify the target graph by name. If the owner's request
  could mean more than one graph, ask which one. Do not guess.
- Each graph has its own owner-approved guide. Read the guide of the target graph
  only, and never apply one graph's conventions to another.
- Read back and verify each write in the graph where it was made.
- Moving or copying content between graphs is two separate operations: read and
  confirm in the source graph, then write and verify in the target graph. Get the
  owner's approval for the plan first.
- Report results per graph, naming the graph each change was made in.

## Troubleshooting

- `502` on `/mcp/<route>`: that graph's container is not running. Check
  `harbor.ps1 status`, and read its logs with `podman logs --tail 20 logseq-mcp-<slug>`.
- `404` on `/mcp/<route>`: the route is wrong (check case and spelling against
  `/mcp`), or the graph was added after the proxy was generated. Run
  `harbor.ps1 update`, which regenerates the proxy config and starts the new graph's container.
- `401`: the bearer token is missing or wrong.
- A graph is missing from `/mcp` after a restart: its container is not running
  or has not finished downloading. Wait, or check its logs.
