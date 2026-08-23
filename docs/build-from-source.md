# Building from Source

Building from source requires the following toolchain on all platforms.

## Prerequisites

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

## Linux (Debian/Ubuntu)

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

## Linux (Fedora/RHEL)

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

## Linux (Arch)

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

## macOS

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

## Windows

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

## Building the CLI

The steps above build the **daemon** release (`mix release dust`, defined in
the umbrella's `mix.exs`). `dustctl` is a separate release defined in
`apps/dust_cli/mix.exs` and is built from inside that app:

```bash
cd apps/dust_cli
MIX_ENV=prod mix release dustctl
```

It is wrapped with [Burrito](https://github.com/burrito-elixir/burrito) to
produce the self-contained, per-platform binaries published on the Releases
page, so this needs Burrito's toolchain (Zig) on top of the dependencies
above. The wrapped binaries are written to `apps/dust_cli/burrito_out/`.

If you only need a working `dustctl` and not the packaged artifacts, the
prebuilt binaries on the
[Releases](https://github.com/AndrewBoessen/dust/releases) page are simpler.
Nix users can build `dustctl` from the flake (`nix build .#dustctl`), which
patches Burrito out and produces a plain mix release — no Zig required.

## Running What You Built

Start the daemon from the release you just built:

```bash
_build/prod/rel/dust/bin/dust start
```

The daemon stores everything under `DUST_DATA_DIR` (default `~/.dust`) and
reads its Erlang node name from `<data-dir>/node_name`, which
`dustctl init` writes. On a fresh build there is nothing there yet, so the
node starts under the placeholder name `dust` until the setup wizard names
it — this is expected, and the name takes effect on the next restart.

With the daemon running, follow
[Getting Started](getting-started.md) from step 3:

```bash
dustctl init   # node name, key store, Tailscale, network setup
dustctl auth   # finish/confirm the Tailscale login
```

`dustctl init` must run before `dustctl auth` — the daemon holds its
Tailscale sidecar back until the node has a name and a key store.

