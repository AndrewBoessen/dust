# CLI Reference

`dustctl` communicates with the local daemon over HTTP. The daemon must be running for most commands. Run `dustctl help` at any time to see the full command reference.

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
