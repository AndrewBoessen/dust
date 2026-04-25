![Dust Logo Banner](./assets/DustBanner.png)

---

[![Build Status](https://github.com/AndrewBoessen/dust/actions/workflows/elixir.yml/badge.svg)](https://github.com/AndrewBoessen/dust/actions)
[![GitHub Release](https://img.shields.io/github/v/release/AndrewBoessen/dust)](https://github.com/AndrewBoessen/dust/releases/latest)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

![Elixir](https://img.shields.io/badge/Elixir-4B275F?style=flat&logo=elixir&logoColor=white)
![Go](https://img.shields.io/badge/Go-00ADD8?style=flat&logo=go&logoColor=white)
![Tailscale](https://img.shields.io/badge/Tailscale-5D5D5D?style=flat&logo=tailscale&logoColor=white)
![RocksDB](https://img.shields.io/badge/RocksDB-7D7D7D?style=flat&logo=databricks&logoColor=white)

_Your data everywhere and nowhere_

Dust is a high-availability, decentralized file storage system. It leverages an actor-mesh architecture to move beyond traditional client-server models, treating data as a distributed pattern of encrypted fragments scattered across a private Tailscale data plane. By combining the fault tolerance of Elixir/OTP with the low-level networking capabilities of Go, Dust provides a unified, local-first filesystem that remains consistent across heterogenous nodes (NAS, Desktop, Laptop, and Mobile).

## Features

## Installation

Dust can be installed from **prebuilt release binaries** or **built from source**. Prebuilt binaries include the Erlang runtime and are fully self-contained — no additional runtime dependencies are required.

### Daemon — Prebuilt Releases

Download the latest release for your platform from the [GitHub Releases](https://github.com/AndrewBoessen/dust/releases) page.

| Platform                      | Artifact                           |
| ----------------------------- | ---------------------------------- |
| Linux x86_64                  | `dust-server-linux-x86_64.tar.gz`  |
| Linux aarch64                 | `dust-server-linux-aarch64.tar.gz` |
| macOS x86_64 (Intel)          | `dust-server-macos-x86_64.tar.gz`  |
| macOS aarch64 (Apple Silicon) | `dust-server-macos-aarch64.tar.gz` |
| Windows x86_64                | `dust-server-windows-x86_64.zip`   |

Verify the download against the `SHA256SUMS.txt` included with each release.

#### Linux

```bash
# Download and extract
curl -LO https://github.com/AndrewBoessen/dust/releases/latest/download/dust-server-linux-x86_64.tar.gz
tar -xzf dust-server-linux-x86_64.tar.gz

# Install the release to /opt/dust
sudo cp -r dust /opt/dust

# Start the daemon
/opt/dust/bin/dust start
```

To install as a systemd service for automatic startup:

```bash
# Copy the service file
sudo cp /opt/dust/service/linux/dust.service /etc/systemd/system/

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable --now dust
```

#### macOS

```bash
# Download and extract
curl -LO https://github.com/AndrewBoessen/dust/releases/latest/download/dust-server-macos-aarch64.tar.gz
tar -xzf dust-server-macos-aarch64.tar.gz

# Move to a system path
sudo mv dust/bin/dust /usr/local/bin/

# Start the daemon
dust start
```

To install as a launchd service:

```bash
cp dust/service/macos/com.dust.daemon.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.dust.daemon.plist
```

#### Windows

1. Download `dust-server-windows-x86_64.zip` from the releases page
2. Extract the archive to `C:\Program Files\Dust\`
3. Add `C:\Program Files\Dust\bin` to your system `PATH`
4. Open a terminal and run:

```powershell
dust start
```

To install as a Windows service, download [WinSW](https://github.com/winsw/winsw) and place `winsw.exe` alongside `dust\service\windows\dust-service.xml` in your install directory:

```powershell
# Copy the service XML and rename winsw to match
Copy-Item "C:\Program Files\Dust\service\windows\dust-service.xml" "C:\Program Files\Dust\"
Rename-Item winsw.exe dust-service.exe
dust-service.exe install
dust-service.exe start
```

---

### CLI (`dustctl`)

`dustctl` is the command-line client for interacting with a running Dust daemon. Download the latest CLI release for your platform from the [GitHub Releases](https://github.com/AndrewBoessen/dust/releases) page.

| Platform                      | Artifact                       |
| ----------------------------- | ------------------------------ |
| Linux x86_64                  | `dustctl-linux-x86_64.tar.gz`  |
| Linux aarch64                 | `dustctl-linux-aarch64.tar.gz` |
| macOS x86_64 (Intel)          | `dustctl-macos-x86_64.tar.gz`  |
| macOS aarch64 (Apple Silicon) | `dustctl-macos-aarch64.tar.gz` |
| Windows x86_64                | `dustctl-windows-x86_64.zip`   |

#### Linux

```bash
# Download and extract
curl -LO https://github.com/AndrewBoessen/dust/releases/latest/download/dustctl-linux-x86_64.tar.gz
tar -xzf dustctl-linux-x86_64.tar.gz

# Install to a directory on your PATH
sudo mv dustctl /usr/local/bin/
```

#### macOS

```bash
# Download and extract
curl -LO https://github.com/AndrewBoessen/dust/releases/latest/download/dustctl-macos-aarch64.tar.gz
tar -xzf dustctl-macos-aarch64.tar.gz

# Install to a directory on your PATH
sudo mv dustctl /usr/local/bin/

# macOS may quarantine the binary on first run — remove the quarantine attribute
xattr -d com.apple.quarantine /usr/local/bin/dustctl
```

#### Windows

1. Download `dustctl-windows-x86_64.zip` from the releases page
2. Extract `dustctl.exe` to `C:\Program Files\Dust\bin\`
3. Ensure `C:\Program Files\Dust\bin` is on your system `PATH`

Verify the install:

```bash
dustctl version
```

---

### Docker

> Docker support coming soon.

## Getting Started

This section walks through setting up a Dust node for the first time. You will need both the daemon and `dustctl` installed before proceeding.

### 1. Configure Tailscale

Dust nodes communicate exclusively over a private Tailscale network. This step only needs to be done once per cluster — all nodes in a cluster share the same tailnet configuration.

Follow the [Tailscale Tags & ACL Policy](#tailscale-tags--acl-policy) setup in the Configuration section, then export your auth key:

```bash
export TS_AUTHKEY="tskey-auth-..."
```

### 2. Authenticate

Connect the node to Tailscale before running the setup wizard:

```bash
dustctl auth
```

If the node is not yet authenticated this command prints an interactive login URL. Open it in a browser to complete authentication, or set `TS_AUTHKEY` in the environment to authenticate non-interactively. Once authenticated, `dustctl auth status` shows the node's Tailscale IP and tag:

```bash
dustctl auth status
```

### 3. Run the Setup Wizard

`dustctl init` walks you through first-time configuration — it creates the data directory and writes a default config:

```bash
dustctl init
```

Follow the on-screen instructions to complete setup.

### 4. Start the Daemon

Start the daemon manually, or install it as a system service so it starts automatically on boot.

**Manual start:**

```bash
dustctl daemon start
```

**Install as a system service** (recommended for always-on nodes):

```bash
dustctl daemon install
```

This registers the daemon with systemd (Linux), launchd (macOS), or the Windows Service Manager depending on your platform.

Check that the daemon is running:

```bash
dustctl daemon status
```

### 5. Unlock the Key Store

Dust encrypts stored data using keys held in a local key store. Unlock it before performing file operations:

```bash
dustctl unlock
```

You will be prompted for your key store passphrase. The store remains unlocked until you explicitly lock it or the daemon restarts.

### 6. Join or Start a Cluster

**First node** — your node is already its own cluster after `dustctl init`. Skip to the next step.

**Additional nodes** — generate an invite token on an existing node, then join from the new one:

```bash
# On an existing node
dustctl invite

# On the new node (use the IP and token printed above)
dustctl join <IP> <TOKEN>
```

You are now ready to use Dust.

## Using the CLI

`dustctl` communicates with the local daemon over HTTP. The daemon must be running for most commands. Run `dustctl help` at any time to see the full command reference.

### File Operations

```bash
# List the root directory
dustctl ls

# Create a directory
dustctl mkdir photos

# Upload a local file
dustctl upload ~/documents/report.pdf

# Download a file by its ID to a local path
dustctl download <FILE_ID> ~/downloads/report.pdf

# Move or rename
dustctl mv photos/old-name.jpg photos/new-name.jpg

# Remove a file or directory
dustctl rm <FILE_ID>

# Show metadata for a file
dustctl stat <FILE_ID>
```

### Cluster

```bash
# List all connected peers
dustctl nodes

# Create an invite token for a new node to join
dustctl invite

# Join an existing cluster
dustctl join <IP> <TOKEN>
```

### Node Status

```bash
# Quick overview of the node and daemon
dustctl status

# Tailscale connectivity details
dustctl auth status
```

### Configuration

```bash
# Print the current runtime configuration
dustctl config

# Change a configuration value at runtime
dustctl config set DUST_API_PORT 4885
```

### Global Options

Any command accepts these flags to override the defaults:

| Flag             | Default       | Description      |
| ---------------- | ------------- | ---------------- |
| `--host HOST`    | `127.0.0.1`   | Daemon host      |
| `--port PORT`    | `4884`        | Daemon port      |
| `--token TOKEN`  | _(from disk)_ | API bearer token |
| `--data-dir DIR` | `~/.dust`     | Data directory   |

## Configuration

### Tailscale Tags & ACL Policy

Dust nodes use **Tailscale tags** to group themselves on the tailnet and **ACL policies** to isolate them from other devices. This configuration is done once per cluster in the [Tailscale Admin Console → Access Controls](https://login.tailscale.com/admin/acls/file):

```json
{
  "tagOwners": {
    "tag:dust-node": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["tag:dust-node"],
      "dst": ["tag:dust-node:*"]
    }
  ]
}
```

This ensures dust nodes can only communicate with each other — not with any other devices on your tailnet.

Once the policy is in place, generate a **tagged auth key** in the admin console under **Settings → Keys**:

1. Enable **Tags** and select `tag:dust-node`.
2. Enable **Pre-approved** (if device approval is enabled).
3. Optionally enable **Reusable** for multi-node deployments.

See the [Getting Started](#getting-started) section for how to use the auth key when setting up a node.

### Environment Variables

#### Tailscale Networking

| Variable      | Required | Default            | Description                                                  |
| ------------- | -------- | ------------------ | ------------------------------------------------------------ |
| `TS_AUTHKEY`  | No       | —                  | Tailscale auth key. If unset, interactive URL login is used. |
| `TS_HOSTNAME` | No       | `dust-node-<name>` | Hostname for the node on the tailnet.                        |
| `TS_TAGS`     | No       | `tag:dust-node`    | Comma-separated Tailscale tags to advertise.                 |
| `JOIN_IP`     | No       | —                  | Tailscale IP of an existing node to join.                    |
| `JOIN_TOKEN`  | No       | —                  | One-time invite token for mesh join.                         |

#### Daemon Configuration

| Variable        | Required | Default     | Description                             |
| --------------- | -------- | ----------- | --------------------------------------- |
| `DUST_DATA_DIR` | No       | `~/.dust`   | Root directory for all persistent data. |
| `DUST_API_PORT` | No       | `4884`      | TCP port for the local HTTP API.        |
| `DUST_API_BIND` | No       | `127.0.0.1` | IP address the HTTP API binds to.       |

## Security

### Interactive URL Authentication

If you authenticate by visiting the Tailscale login URL (instead of using a `TS_AUTHKEY`), **the authenticating user must be listed in `tagOwners`** for the configured tag. For example, if your policy has:

```json
"tagOwners": { "tag:dust-node": ["alice@example.com"] }
```

Only `alice@example.com` can authenticate and receive the tag. If a different user authenticates, the node joins **without the tag**, which means:

- ACL isolation rules **will not apply** — the node can see and be seen by other tailnet devices.
- Other dust nodes **will not discover it** as a peer (peer discovery filters by tag).
- The sidecar will detect this and **exit with a fatal error** to prevent running untagged.

**Recommendation:** Use a tagged `TS_AUTHKEY` for production. It guarantees the correct tags regardless of who deploys the node.

---

## Development

### Building from Source

Building from source requires the following toolchain on all platforms.

#### Prerequisites

| Dependency                                 | Version       | Purpose                                                                   |
| ------------------------------------------ | ------------- | ------------------------------------------------------------------------- |
| [Erlang/OTP](https://www.erlang.org/)      | 28.1+         | Runtime and build system                                                  |
| [Elixir](https://elixir-lang.org/)         | 1.19+         | Application language                                                      |
| [Go](https://go.dev/)                      | 1.22+         | Tailscale `tsnet` sidecar                                                 |
| [Rust](https://rustup.rs/)                 | stable        | Reed-Solomon NIF ([`rs_simd`](https://hex.pm/packages/reed_solomon_simd)) |
| [CMake](https://cmake.org/)                | 3.16+         | RocksDB NIF compilation                                                   |
| [GCC / Clang / MSVC](https://gcc.gnu.org/) | C++17 capable | RocksDB and Argon2 native compilation                                     |
| [Git](https://git-scm.com/)                | 2.x+          | Source checkout                                                           |
| **libsnappy-dev**                          | —             | Compression library for RocksDB                                           |

> **Note:** We recommend using [asdf](https://asdf-vm.com/) to manage Erlang, Elixir, and Go versions. The `.tool-versions` file in the repo tracks the exact versions used.

#### Linux (Debian/Ubuntu)

```bash
# Install system dependencies
sudo apt-get update
sudo apt-get install -y \
  build-essential \
  cmake \
  git \
  libsnappy-dev \
  libncurses-dev \
  libssl-dev \
  autoconf \
  curl

# Install asdf (recommended) and plugins
git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0
echo '. "$HOME/.asdf/asdf.sh"' >> ~/.bashrc
source ~/.bashrc

asdf plugin add erlang
asdf plugin add elixir
asdf plugin add golang
asdf plugin add rust

# Install exact versions from .tool-versions
cd dust
asdf install

# Or install manually:
#   Erlang 28.1, Elixir 1.19.0, Go 1.22+, Rust stable

# Install Elixir dependencies
mix deps.get

# Build the Go sidecar and place it in the priv directory
cd apps/dust_bridge/native/tsnet_sidecar
go build -o tsnet_sidecar
cd ../../../..
mkdir -p apps/dust_bridge/priv
cp apps/dust_bridge/native/tsnet_sidecar/tsnet_sidecar apps/dust_bridge/priv/tsnet_sidecar

# Compile (development)
mix compile

# Build a production release
MIX_ENV=prod mix release dust

# The release is at _build/prod/rel/dust/
_build/prod/rel/dust/bin/dust start
```

#### Linux (Fedora/RHEL)

```bash
# Install system dependencies
sudo dnf install -y \
  gcc gcc-c++ \
  cmake \
  git \
  snappy-devel \
  ncurses-devel \
  openssl-devel \
  autoconf \
  curl

# Then follow the same Erlang/Elixir/Go/Rust setup and build steps as above
```

#### Linux (Arch)

```bash
# Install system dependencies
sudo pacman -S --needed \
  base-devel \
  cmake \
  git \
  snappy \
  ncurses \
  openssl \
  curl

# Then follow the same Erlang/Elixir/Go/Rust setup and build steps as above
```

#### macOS

```bash
# Install Homebrew if not present
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install system dependencies
brew install cmake snappy openssl autoconf

# Install asdf and plugins
brew install asdf
asdf plugin add erlang
asdf plugin add elixir
asdf plugin add golang
asdf plugin add rust

# Install Erlang (with OpenSSL from Homebrew)
export KERL_CONFIGURE_OPTIONS="--with-ssl=$(brew --prefix openssl)"
cd dust
asdf install

# Install Elixir dependencies
mix deps.get

# Build the Go sidecar and place it in the priv directory
cd apps/dust_bridge/native/tsnet_sidecar
go build -o tsnet_sidecar
cd ../../../..
mkdir -p apps/dust_bridge/priv
cp apps/dust_bridge/native/tsnet_sidecar/tsnet_sidecar apps/dust_bridge/priv/tsnet_sidecar

# Compile (development)
mix compile

# Build a production release
MIX_ENV=prod mix release dust

# The release is at _build/prod/rel/dust/
_build/prod/rel/dust/bin/dust start
```

#### Windows

Building on Windows requires extra tooling for the native C/C++ and Rust NIFs.

1. **Install Visual Studio Build Tools** with the "Desktop development with C++" workload from [Visual Studio Downloads](https://visualstudio.microsoft.com/downloads/).

2. **Install dependencies:**

```powershell
# Install Chocolatey (if not present)
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# Install build tools
choco install -y cmake git golang rustup.install

# Install Erlang and Elixir
choco install -y erlang --version=28.1
choco install -y elixir --version=1.19.0

# Install snappy via vcpkg
git clone https://github.com/microsoft/vcpkg.git C:\vcpkg
C:\vcpkg\bootstrap-vcpkg.bat
C:\vcpkg\vcpkg install snappy:x64-windows
$env:CMAKE_PREFIX_PATH = "C:\vcpkg\installed\x64-windows"
```

1. **Build:**

```powershell
# Open a Developer Command Prompt or set up the VS environment
cd dust

# Install Elixir dependencies
mix deps.get

# Build the Go sidecar and place it in the priv directory
cd apps\dust_bridge\native\tsnet_sidecar
$env:CGO_ENABLED = "0"
go build -o tsnet_sidecar.exe
cd ..\..\..\..
New-Item -ItemType Directory -Force -Path apps\dust_bridge\priv | Out-Null
Copy-Item apps\dust_bridge\native\tsnet_sidecar\tsnet_sidecar.exe apps\dust_bridge\priv\tsnet_sidecar.exe

# Compile
mix compile

# Build a production release
$env:MIX_ENV = "prod"
mix release dust

# The release is at _build\prod\rel\dust\
_build\prod\rel\dust\bin\dust start
```
