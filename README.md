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

### Linux

### MacOS

### Windows

### Docker

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

| Variable      | Required | Default            | Description                                                  |
| ------------- | -------- | ------------------ | ------------------------------------------------------------ |
| `TS_AUTHKEY`  | No       | —                  | Tailscale auth key. If unset, interactive URL login is used. |
| `TS_HOSTNAME` | No       | `dust-node-<name>` | Hostname for the node on the tailnet.                        |
| `TS_TAGS`     | No       | `tag:dust-node`    | Comma-separated Tailscale tags to advertise.                 |
| `JOIN_IP`     | No       | —                  | Tailscale IP of an existing node to join.                    |
| `JOIN_TOKEN`  | No       | —                  | One-time invite token for mesh join.                         |

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
