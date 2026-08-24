# CLI Reference

`dustctl` communicates with the local daemon over HTTP. The daemon must be running for most commands. Run `dustctl help` at any time to see the full command reference.

## First-Time Setup

On a new node these run in order — `dustctl init` before `dustctl auth`:

```bash
# Start the daemon (all other commands talk to it)
dustctl daemon start

# Setup wizard: node name, key store, Tailscale start, network setup
dustctl init

# Finish or confirm the Tailscale login
dustctl auth
```

`dustctl auth` cannot produce a login URL until `dustctl init` has run —
the daemon keeps its Tailscale sidecar stopped until the node has a name
and a key store. See [Getting Started](getting-started.md) for the full
walkthrough.

If you change the node's name, `dustctl init` restarts the daemon for you
before continuing — Erlang's node identity is fixed at boot, so nothing
past that point (Tailscale, joining) can trust a name that only exists in
config until the process actually restarts. This may prompt for your
password if Dust runs as a system service, the same as `dustctl daemon
install` already does. If it can't confirm the restart, it stops and
tells you to restart manually and run `dustctl init` again.

Prefer a browser? See [Web UI](#web-ui) below — it's a full alternative
to this wizard, with one difference worth knowing before you use it.

## File Operations

```bash
# List the root directory
dustctl ls

# Create a directory
dustctl mkdir photos

# Upload a local file
dustctl upload ~/documents/report.pdf

# Download a file by its ID to a local path
dustctl download <FILE_PATH> <DEST_PATH>

# Move or rename
dustctl mv <OLD_PATH> <NEW_PATH>

# Remove a file or directory
dustctl rm <FILE_PATH>

# Show metadata for a file
dustctl stat <FILE_PATH>
```

## Cluster

```bash
# List all connected peers
dustctl nodes

# Create an invite token for a new node to join
# (the key store must be unlocked; the token is single-use
#  and expires after 10 minutes)
dustctl invite

# Join an existing cluster
dustctl join <IP> <TOKEN>

# Join without being asked to confirm replacing the master key
dustctl join <IP> <TOKEN> --force
```

Joining adopts the network's OTP cookie **and** its master key — the first
makes the node a cluster member, the second lets it read the cluster's
files. Replacing the master key orphans anything this node already stored
under its own key, so `dustctl join` asks first and reports what would be
lost. A node holding no data adopts the key without prompting. Declining
leaves the node untouched and does not join.

The joining node must already be connected to Tailscale
(`dustctl auth`) and have its key store unlocked. See
[Getting Started → Adding More Nodes](getting-started.md#5-adding-more-nodes).

## Key Store

File operations need an unlocked key store. It locks on daemon restart.

```bash
# Unlock (prompts for the passphrase)
dustctl unlock

# Unlock non-interactively
dustctl unlock --password <PASSPHRASE>   # -p also works

# Lock — also stops serving secrets and invalidates invite tokens
dustctl lock
```

On first use the passphrase creates the node's key store. Each node has
its own passphrase; joining a network does not change it.

## Node Status

```bash
# Quick overview of the node and daemon
dustctl status

# Tailscale connectivity details
dustctl auth status

# Re-check Tailscale, printing a login URL if the node needs one
dustctl auth

# Clear the local Tailscale state so the node can log in again
dustctl auth logout
```

## Web UI

The daemon serves a browser UI (Phoenix LiveView) on `ui_port`, bound to
`127.0.0.1` by default.

```bash
# Open the web UI in your browser (also the default: `dustctl ui`)
dustctl ui open

# Print the UI URL and whether it is reachable
dustctl ui status
```

The UI covers the same first-time setup as `dustctl init` — naming the
node, the key-store passphrase, Tailscale (it shows the login URL and
waits inline, so there's no separate `dustctl auth` step), and
create-or-join — as long as no key store exists yet; visiting the address
directly redirects there automatically in that case.

**Unlike `dustctl init`, it does not restart the daemon for you.** A
rename needs that restart for the same reason noted above, but the
restart can't be automated safely from a page the daemon itself is
serving — the browser session would need to survive the daemon
disappearing out from under it. Choosing **join** completes the cookie
and master-key adoption normally, then shows a **"Joined — one more
step"** screen with the exact restart command for your platform; run it,
then reload and log in. Choosing **create** doesn't need a restart before
you finish (there's no peer yet), but restart before inviting anyone, for
the same reason.

## Garbage Collection

```bash
# Statistics from the last sweep
dustctl gc stats

# Trigger a sweep immediately
dustctl gc sweep
```

A sweep reconciles local storage against the distributed manifest and
evicts local copies of chunks that are already replicated on at least
`replication_factor` other online nodes.

## Configuration

```bash
# Print the current runtime configuration
dustctl config

# Change a configuration value at runtime
dustctl config set replication_factor 3
```

`config set` takes the key names used in `config.yaml`, not the environment
variable names. The runtime-settable keys are `replication_factor`,
`disk_quota_bytes`, `stale_node_timeout_ms`, `max_reconstruct_per_sweep`,
`api_port`, `api_bind`, `ui_port`, `ui_bind`, `root_dir_id` and
`node_name`. `persist_dir`, `erasure_k` and `erasure_m` are fixed at boot.
Changing `node_name` takes effect on the next daemon restart — see
[Configuration → Node Names](configuration.md#node-names-and-erlang-distribution).

## Global Options

Any command accepts these flags to override the defaults:

| Flag             | Default        | Description      |
| ---------------- | -------------- | ---------------- |
| `--host HOST`    | `127.0.0.1`    | Daemon host      |
| `--port PORT`    | `4884`         | Daemon port      |
| `--token TOKEN`  | _(from disk)_  | API bearer token |
| `--data-dir DIR` | _(asked of the daemon, else `~/.dust`)_ | Data directory |

They may be written before or after the command:

```bash
dustctl --port 4899 status
dustctl status --port 4899
```

Unless `--data-dir` is given, `dustctl` asks the running daemon where its
data directory is, so it works against a daemon using a non-default
`persist_dir` without extra flags.

## Help and Version

```bash
dustctl help          # or --help, or dustctl with no arguments
dustctl version       # or --version
```

These never contact the daemon, so they work before `dustctl init`, with
the daemon stopped, and before Tailscale is authenticated.
