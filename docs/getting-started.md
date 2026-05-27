# Getting Started

This guide walks through setting up a Dust node for the first time. You
will need both the daemon and `dustctl` installed before proceeding —
see the install guide for your platform:

- [Linux](install/linux.md)
- [macOS](install/macos.md)
- [NixOS](install/nixos.md)
- [Windows](install/windows.md)

## 1. Configure Tailscale

Dust nodes communicate exclusively over a private Tailscale network. This step only needs to be done once per cluster — all nodes in a cluster share the same tailnet configuration.

Follow the [Tailscale Tags & ACL Policy](configuration.md#tailscale-tags--acl-policy) setup in the Configuration section, then export your auth key:

```bash
export TS_AUTHKEY="tskey-auth-..."
```

## 2. Authenticate

Connect the node to Tailscale before running the setup wizard:

```bash
dustctl auth
```

If the node is not yet authenticated this command prints an interactive login URL. Open it in a browser to complete authentication, or set `TS_AUTHKEY` in the environment to authenticate non-interactively. Once authenticated, `dustctl auth status` shows the node's Tailscale IP and tag:

```bash
dustctl auth status
```

## 3. Run the Setup Wizard

`dustctl init` walks you through first-time configuration — it creates the data directory and writes a default config:

```bash
dustctl init
```

Follow the on-screen instructions to complete setup.

## 4. Start the Daemon

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

## 5. Unlock the Key Store

Dust encrypts stored data using keys held in a local key store. Unlock it before performing file operations:

```bash
dustctl unlock
```

You will be prompted for your key store passphrase. The store remains unlocked until you explicitly lock it or the daemon restarts.

## 6. Join or Start a Cluster

**First node** — your node is already its own cluster after `dustctl init`. Skip to the next step.

**Additional nodes** — generate an invite token on an existing node, then join from the new one:

```bash
# On an existing node
dustctl invite

# On the new node (use the IP and token printed above)
dustctl join <IP> <TOKEN>
```

You are now ready to use Dust. See the [CLI Reference](cli.md) for a full list of commands.
