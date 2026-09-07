# Configuration

## Tailscale Tags & ACL Policy

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

See [Getting Started](getting-started.md) for how to use the auth key when setting up a node.

## Node Names and Erlang Distribution

Each node has a short `node_name`, chosen during `dustctl init` and stored
in `<persist_dir>/config.yaml`. It has to be unique across the cluster —
it is both the host part of the node's Erlang atom (`dust@<name>`) and the
suffix of its Tailscale hostname (`dust-node-<name>`).

Two constraints follow from how peers reach each other. `Dust.Bridge.EPMD`
routes distribution **by name**: it asks the Tailscale sidecar to resolve
`dust-node-<name>` to a current tailnet IP and opens a local proxy to it,
so both peers announce the same `dust@<name>` atom no matter how their IPs
move.

1. **Node names must not contain a dot.** They are short names
   (`RELEASE_DISTRIBUTION=sname`), not fully-qualified hostnames. A name
   with a dot is rejected during connection setup.
2. **Distribution must stay in short-name mode.** Under long names
   (`RELEASE_DISTRIBUTION=name`), Erlang rejects any dotless host that is
   not a literal IP address, and every peer connection fails with
   `** Hostname <name> is illegal **` — after the bridge has already
   resolved and proxied the peer, which makes the error look unrelated to
   naming. `rel/env.sh.eex` and `rel/env.bat.eex` set `sname`; don't
   override `RELEASE_DISTRIBUTION`.

All nodes in a cluster must agree on this: a long-name node and a
short-name node cannot connect to each other.

### Renaming requires a restart

Erlang fixes a node's distribution identity (`Node.self/0`) at VM boot,
built from the `node_name` file the release's boot script reads before
the Elixir VM even starts. Changing `node_name` at runtime — via
`dustctl init`, `dustctl config set node_name <name>`, or the Web UI —
updates `config.yaml` and that file immediately, but the *running*
process keeps answering to its old identity until it actually restarts.
Nothing that depends on the name being current (bringing up Tailscale,
joining a network) can be trusted until that happens.

`dustctl init` restarts the daemon itself right after a rename, detecting
whether it's running as a system service or was started manually and
using the matching mechanism — this may prompt for a password on a
service-managed install. The Web UI's setup wizard does not automate
this (restarting the very daemon serving the page mid-session isn't
straightforward); it shows the exact restart command to run by hand
instead when a rename needs one. See
[Getting Started](getting-started.md#3-run-the-setup-wizard) and
[Getting Started → Using the Web UI Instead](getting-started.md#using-the-web-ui-instead).

## Environment Variables

### Tailscale Networking

| Variable      | Required | Default            | Description                                                  |
| ------------- | -------- | ------------------ | ------------------------------------------------------------ |
| `TS_AUTHKEY`  | No       | —                  | Tailscale auth key. If unset, interactive URL login is used. |
| `TS_HOSTNAME` | No       | `dust-node-<name>` | Hostname for the node on the tailnet.                        |
| `TS_TAGS`     | No       | `tag:dust-node`    | Comma-separated Tailscale tags to advertise.                 |
| `JOIN_IP`     | No       | —                  | Tailscale IP of an existing node to join.                    |
| `JOIN_TOKEN`  | No       | —                  | One-time invite token for mesh join.                         |

### Daemon Configuration

| Variable        | Required | Default     | Description                             |
| --------------- | -------- | ----------- | --------------------------------------- |
| `DUST_DATA_DIR` | No       | `~/.dust`   | Root directory for all persistent data. |
| `DUST_API_PORT` | No       | `4884`      | TCP port for the local HTTP API.        |
| `DUST_API_BIND` | No       | `127.0.0.1` | IP address the HTTP API binds to.       |

## NixOS

The flake's NixOS module (`dust.nixosModules.default`) exposes the daemon
under `services.dust`. Common options:

| Option                           | Default            | Description                                                                                           |
| -------------------------------- | ------------------ | ----------------------------------------------------------------------------------------------------- |
| `services.dust.enable`           | `false`            | Enable the daemon as a systemd service.                                                               |
| `services.dust.package`          | `pkgs.dust`        | Package to run (typically from the flake's `overlays.default`).                                       |
| `services.dust.user`             | `"dust"`           | System user the daemon runs as.                                                                       |
| `services.dust.group`            | `"dust"`           | System group the daemon runs as.                                                                      |
| `services.dust.dataDir`          | `/var/lib/dust`    | Persistent state directory (sets `DUST_DATA_DIR` and `HOME`).                                         |
| `services.dust.logDir`           | `/var/log/dust`    | Log directory.                                                                                        |
| `services.dust.apiBind`          | `"127.0.0.1"`      | API bind address (`DUST_API_BIND`).                                                                   |
| `services.dust.apiPort`          | `4884`             | API TCP port (`DUST_API_PORT`).                                                                       |
| `services.dust.nodeName`         | `"dust@127.0.0.1"` | `RELEASE_NODE` for the BEAM node.                                                                     |
| `services.dust.cookieFile`       | `null`             | Path to a file with the Erlang distribution cookie (kept outside the Nix store).                      |
| `services.dust.environmentFile`  | `null`             | systemd `EnvironmentFile=` for secrets (e.g. `TS_AUTHKEY`).                                           |
| `services.dust.openFirewall`     | `false`            | Open `apiPort` in the firewall. Off by default — Dust expects API traffic over loopback or Tailscale. |
| `services.dust.extraEnvironment` | `{ }`              | Extra env vars on the unit (e.g. `{ TS_TAGS = "tag:dust-node"; }`).                                   |

Example with secrets in a sops-nix file:

```nix
{
  services.dust = {
    enable = true;
    cookieFile = config.sops.secrets."dust/cookie".path;
    environmentFile = config.sops.secrets."dust/env".path;
    extraEnvironment = {
      TS_HOSTNAME = "dust-node-${config.networking.hostName}";
      TS_TAGS = "tag:dust-node";
    };
  };
}
```

`dustctl` invocations like `dustctl daemon install` / `uninstall` /
`start` / `stop` are short-circuited on NixOS — the module owns the
unit, so the CLI returns a `nixos_managed` error instead of trying to
write to `/etc/systemd/system/`.

### Granting CLI access to the API token

The daemon writes its bearer token to `<dataDir>/api_token` mode `0640
dust:dust`. Any account in the `dust` group can read it (and traverse
the `0750` `dataDir`). Add operators with:

```nix
users.users.alice.extraGroups = [ "dust" ];
```

After `nixos-rebuild switch`, the user must start a fresh login session
for the membership to take effect (`newgrp dust` works as a one-off in
the current shell). If you'd rather not grant group membership, pass
the token explicitly per-invocation with `dustctl --token <hex> …`.
