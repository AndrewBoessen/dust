# macOS Install

Install the Dust daemon and `dustctl` CLI on macOS from prebuilt
release binaries. Releases bundle the Erlang runtime and are fully
self-contained — no additional runtime dependencies are required.

Available artifacts on the
[GitHub Releases](https://github.com/AndrewBoessen/dust/releases) page:

| Component | Artifact                           |
| --------- | ---------------------------------- |
| Daemon    | `dust-server-macos-x86_64.tar.gz`  |
| Daemon    | `dust-server-macos-aarch64.tar.gz` |
| CLI       | `dustctl_macos_x86_64`             |
| CLI       | `dustctl_macos_aarch64`            |

Use the `aarch64` builds on Apple Silicon and the `x86_64` builds on
Intel. Verify each download against the `SHA256SUMS.txt` included with
the release.

## Daemon

```bash
# Download and extract
curl -LO https://github.com/AndrewBoessen/dust/releases/latest/download/dust-server-macos-aarch64.tar.gz
tar -xzf dust-server-macos-aarch64.tar.gz

# Move to a system path
sudo mv dust/bin/dust /usr/local/bin/

# Start the daemon
dust start
```

To install as a launchd agent so it starts on login:

```bash
dustctl daemon install
```

This writes `~/Library/LaunchAgents/com.dust.daemon.plist` and loads it
via `launchctl`. To remove it, run `dustctl daemon uninstall`.

## CLI (`dustctl`)

```bash
# Download the binary (Apple Silicon)
curl -LO https://github.com/AndrewBoessen/dust/releases/latest/download/dustctl_macos_aarch64

# Make it executable and install to a directory on your PATH
chmod +x dustctl_macos_aarch64
sudo mv dustctl_macos_aarch64 /usr/local/bin/dustctl

# macOS may quarantine the binary on first run — remove the quarantine attribute
xattr -d com.apple.quarantine /usr/local/bin/dustctl
```

For Intel Macs, replace `dustctl_macos_aarch64` with `dustctl_macos_x86_64`.

Verify the install:

```bash
dustctl version
```

---

**Next:** [Getting Started](../getting-started.md) — first-node setup
walkthrough.
