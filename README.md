![Dust Logo Banner](./assets/DustBanner.png)

---

[![Build Status](https://github.com/AndrewBoessen/dust/actions/workflows/elixir.yml/badge.svg)](https://github.com/AndrewBoessen/dust/actions)
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

### Prebuilt Releases

Download the latest release for your platform from the [GitHub Releases](https://github.com/AndrewBoessen/dust/releases) page.

| Platform | Artifact |
|----------|----------|
| Linux x86_64 | `dust-linux-x86_64.tar.gz` |
| Linux aarch64 | `dust-linux-aarch64.tar.gz` |
| macOS x86_64 (Intel) | `dust-macos-x86_64.tar.gz` |
| macOS aarch64 (Apple Silicon) | `dust-macos-aarch64.tar.gz` |
| Windows x86_64 | `dust-windows-x86_64.zip` |

Verify the download against the `SHA256SUMS.txt` included with each release.

#### Linux

```bash
# Download and extract
curl -LO https://github.com/AndrewBoessen/dust/releases/latest/download/dust-linux-x86_64.tar.gz
tar -xzf dust-linux-x86_64.tar.gz

# Move to a system path
sudo mv dust/bin/dust /usr/local/bin/

# Start the daemon
dust start
```

To install as a systemd service for automatic startup:

```bash
# Copy the service file
sudo cp dust/lib/dust-0.1.0/priv/service/linux/dust.service /etc/systemd/system/

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable --now dust
```

#### macOS

```bash
# Download and extract
curl -LO https://github.com/AndrewBoessen/dust/releases/latest/download/dust-macos-aarch64.tar.gz
tar -xzf dust-macos-aarch64.tar.gz

# Move to a system path
sudo mv dust/bin/dust /usr/local/bin/

# Start the daemon
dust start
```

To install as a launchd service:

```bash
cp dust/lib/dust-0.1.0/priv/service/macos/com.dust.daemon.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.dust.daemon.plist
```

#### Windows

1. Download `dust-windows-x86_64.zip` from the releases page
2. Extract the archive to `C:\Program Files\Dust\`
3. Add `C:\Program Files\Dust\bin` to your system `PATH`
4. Open a terminal and run:

```powershell
dust start
```

To install as a Windows service, download [WinSW](https://github.com/winsw/winsw) and place `winsw.exe` alongside `dust-service.xml` in the install directory:

```powershell
# Rename winsw to match the service XML
Rename-Item winsw.exe dust-service.exe
dust-service.exe install
dust-service.exe start
```

---

### Building from Source

Building from source requires the following toolchain on all platforms.

#### Prerequisites

| Dependency | Version | Purpose |
|------------|---------|---------|
| [Erlang/OTP](https://www.erlang.org/) | 28.1+ | Runtime and build system |
| [Elixir](https://elixir-lang.org/) | 1.19+ | Application language |
| [Go](https://go.dev/) | 1.22+ | Tailscale `tsnet` sidecar |
| [Rust](https://rustup.rs/) | stable | Reed-Solomon NIF ([`rs_simd`](https://hex.pm/packages/reed_solomon_simd)) |
| [CMake](https://cmake.org/) | 3.16+ | RocksDB NIF compilation |
| [GCC / Clang / MSVC](https://gcc.gnu.org/) | C++17 capable | RocksDB and Argon2 native compilation |
| [Git](https://git-scm.com/) | 2.x+ | Source checkout |
| **libsnappy-dev** | — | Compression library for RocksDB |

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

# Build the Go sidecar
cd apps/dust_bridge/native/tsnet_sidecar
go build -o tsnet_sidecar
cd ../../../..

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

# Build the Go sidecar
cd apps/dust_bridge/native/tsnet_sidecar
go build -o tsnet_sidecar
cd ../../../..

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

3. **Build:**

```powershell
# Open a Developer Command Prompt or set up the VS environment
cd dust

# Install Elixir dependencies
mix deps.get

# Build the Go sidecar
cd apps\dust_bridge\native\tsnet_sidecar
$env:CGO_ENABLED = "0"
go build -o tsnet_sidecar.exe
cd ..\..\..\..

# Compile
mix compile

# Build a production release
$env:MIX_ENV = "prod"
mix release dust

# The release is at _build\prod\rel\dust\
_build\prod\rel\dust\bin\dust start
```

---

### Docker

> Docker support coming soon.

## Getting Started

## Configuration

### Tailscale Tags & ACL Policy

Dust nodes use **Tailscale tags** to group themselves on the tailnet and **ACL policies** to isolate them from other devices. Configure this in the [Tailscale Admin Console → Access Controls](https://login.tailscale.com/admin/acls/file):

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

### Auth Key

Generate a **tagged auth key** in the admin console under **Settings → Keys**:

1. Enable **Tags** and select `tag:dust-node`.
2. Enable **Pre-approved** (if device approval is enabled).
3. Optionally enable **Reusable** for multi-node deployments.

```bash
export TS_AUTHKEY="tskey-auth-..."
```

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

| Variable        | Required | Default      | Description                                       |
| --------------- | -------- | ------------ | ------------------------------------------------- |
| `DUST_DATA_DIR` | No       | `~/.dust`    | Root directory for all persistent data.            |
| `DUST_API_PORT` | No       | `4884`       | TCP port for the local HTTP API.                   |
| `DUST_API_BIND` | No       | `127.0.0.1`  | IP address the HTTP API binds to.                  |

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
