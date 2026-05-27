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

## Install

Prebuilt release binaries include the Erlang runtime and have no
additional runtime dependencies. Pick your platform:

| Platform | Guide                                              |
| -------- | -------------------------------------------------- |
| Linux    | [docs/install/linux.md](docs/install/linux.md)     |
| macOS    | [docs/install/macos.md](docs/install/macos.md)     |
| NixOS    | [docs/install/nixos.md](docs/install/nixos.md)     |
| Windows  | [docs/install/windows.md](docs/install/windows.md) |

To compile from source instead, see
[docs/build-from-source.md](docs/build-from-source.md).

## Quick Start

Once the daemon and `dustctl` are installed:

```bash
dustctl daemon start  # start the daemon (all other commands talk to it)
dustctl auth          # connect node to Tailscale (skip if TS_AUTHKEY is set)
dustctl init          # setup wizard: data dir, key store unlock, network setup
```

See [Getting Started](docs/getting-started.md) for the full first-node
walkthrough, including joining an existing cluster and installing the
daemon as a system service.

## Documentation

- [Getting Started](docs/getting-started.md) — first-node setup walkthrough
- [CLI Reference](docs/cli.md) — full `dustctl` command list
- [Configuration](docs/configuration.md) — Tailscale ACLs, environment variables, NixOS module options
- [Security](docs/security.md) — authentication and tag enforcement notes
- [Building from Source](docs/build-from-source.md) — toolchain setup and per-OS build steps

## License

Apache 2.0 — see [LICENSE](LICENSE).
