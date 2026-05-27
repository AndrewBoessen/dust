# Getting Started

This guide walks through setting up a Dust node for the first time. You
will need both the daemon and `dustctl` installed before proceeding —
see the install guide for your platform:

- [Linux](install/linux.md)
- [macOS](install/macos.md)
- [NixOS](install/nixos.md)
- [Windows](install/windows.md)

All `dustctl` commands except `daemon start` talk to the local daemon
over HTTP, so the daemon needs to be running before you can authenticate,
run the setup wizard, or operate on files.

## 1. Configure Tailscale

Dust nodes communicate exclusively over a private Tailscale network. This step only needs to be done once per cluster — all nodes in a cluster share the same tailnet configuration.

Follow the [Tailscale Tags & ACL Policy](configuration.md#tailscale-tags--acl-policy) setup in the Configuration section. Then either export a tagged auth key for non-interactive setup:

```bash
export TS_AUTHKEY="tskey-auth-..."
```

…or skip this and use interactive browser login in step 3.

## 2. Start the Daemon

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

## 3. Authenticate to Tailscale

Connect the node to Tailscale:

```bash
dustctl auth
```

If you set `TS_AUTHKEY` before starting the daemon, the sidecar will
already be authenticated and this command will just confirm the
connection. Otherwise it prints an interactive login URL — open it in
a browser to complete authentication, then `dustctl auth` polls until
the node is connected.

Once authenticated, `dustctl auth status` shows the node's Tailscale IP and tag:

```bash
dustctl auth status
```

## 4. Run the Setup Wizard

`dustctl init` walks you through first-time configuration — it creates the data directory, unlocks (or creates) the local key store, and configures the network:

```bash
dustctl init
```

The wizard will:

1. Create the data directory (`~/.dust` by default).
2. Verify the daemon is running.
3. Prompt for a key-store passphrase — on first use this creates a new key, on later runs it unlocks the existing one.
4. Offer to create a new network (this node becomes the genesis node) or join an existing one.

Follow the on-screen prompts to finish setup.

## 5. Adding More Nodes

If you chose "Create a new network" in the wizard, your node is already its own cluster. To add another node, generate an invite token on this node and use it from the new one:

```bash
# On the existing node
dustctl invite

# On the new node (use the IP and token printed above)
dustctl join <IP> <TOKEN>
```

You are now ready to use Dust. See the [CLI Reference](cli.md) for a full list of commands.

## Locking and Unlocking Later

The key store stays unlocked until you explicitly lock it or the daemon restarts. After a restart you'll need to unlock again before performing file operations:

```bash
dustctl unlock   # prompts for the passphrase
dustctl lock     # lock the key store
```
