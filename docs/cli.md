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
dustctl invite

# Join an existing cluster
dustctl join <IP> <TOKEN>
```

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

## Configuration

```bash
# Print the current runtime configuration
dustctl config

# Change a configuration value at runtime
dustctl config set DUST_API_PORT 4885
```

## Global Options

Any command accepts these flags to override the defaults:

| Flag             | Default       | Description      |
| ---------------- | ------------- | ---------------- |
| `--host HOST`    | `127.0.0.1`   | Daemon host      |
| `--port PORT`    | `4884`        | Daemon port      |
| `--token TOKEN`  | _(from disk)_ | API bearer token |
| `--data-dir DIR` | `~/.dust`     | Data directory   |
