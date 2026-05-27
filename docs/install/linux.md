# Linux Install

Install the Dust daemon and `dustctl` CLI on Linux from prebuilt
release binaries. Releases bundle the Erlang runtime and are fully
self-contained — no additional runtime dependencies are required.

Available artifacts on the
[GitHub Releases](https://github.com/AndrewBoessen/dust/releases) page:

| Component | Artifact                           |
| --------- | ---------------------------------- |
| Daemon    | `dust-server-linux-x86_64.tar.gz`  |
| Daemon    | `dust-server-linux-aarch64.tar.gz` |
| CLI       | `dustctl_linux_x86_64`             |
| CLI       | `dustctl_linux_aarch64`            |

Verify each download against the `SHA256SUMS.txt` included with the
release.

## Daemon

```bash
# Download and extract
curl -LO https://github.com/AndrewBoessen/dust/releases/latest/download/dust-server-linux-x86_64.tar.gz
tar -xzf dust-server-linux-x86_64.tar.gz

# Install the release to /opt/dust
sudo cp -r dust /opt/dust

# Start the daemon
/opt/dust/bin/dust start
```

With the daemon running, install it as a systemd service so it starts on
boot:

```bash
dustctl daemon install
```

`dustctl daemon install` writes a unit to `/etc/systemd/system/dust.service`
(via `sudo`), runs `systemctl daemon-reload`, and enables `dust`. To
remove it later, run `dustctl daemon uninstall`.

## CLI (`dustctl`)

```bash
# Download the binary
curl -LO https://github.com/AndrewBoessen/dust/releases/latest/download/dustctl_linux_x86_64

# Make it executable and install to a directory on your PATH
chmod +x dustctl_linux_x86_64
sudo mv dustctl_linux_x86_64 /usr/local/bin/dustctl
```

Verify the install:

```bash
dustctl version
```

---

**Next:** [Getting Started](../getting-started.md) — first-node setup
walkthrough.
