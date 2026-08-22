# Getting Started

This guide walks through setting up a Dust node for the first time. You
will need both the daemon and `dustctl` installed before proceeding —
see the install guide for your platform:

- [Linux](install/linux.md)
- [macOS](install/macos.md)
- [NixOS](install/nixos.md)
- [Windows](install/windows.md)

All `dustctl` commands except `daemon start` talk to the local daemon
over HTTP, so the daemon needs to be running before you can run the
setup wizard, authenticate, or operate on files.

## Setup Order

Run the steps below in order. In particular, **`dustctl init` must be run
before `dustctl auth`** on a brand-new node:

```bash
dustctl daemon start   # 1. start the daemon
dustctl init           # 2. name the node, create the key store, start Tailscale
dustctl auth           # 3. finish/confirm Tailscale login
```

The daemon deliberately does **not** start its Tailscale sidecar on a
node that has no key store yet (no `<data-dir>/master.key`). Tailscale
identity is keyed to the node's hostname, so bringing the sidecar up
before you have chosen a device name would register the node on your
tailnet as the placeholder `dust-node-dust`, and renaming it later
forces a re-authentication.

`dustctl init` is what chooses the name, creates the key store, and
*then* starts the sidecar. Until it has run, there is no Tailscale
session to report on: `dustctl auth` will wait for a login URL that
never arrives and eventually print `Could not retrieve auth URL`. If you
see that message on a fresh node, run `dustctl init` first.

## 1. Configure Tailscale

Dust nodes communicate exclusively over a private Tailscale network. This step only needs to be done once per cluster — all nodes in a cluster share the same tailnet configuration.

Follow the [Tailscale Tags & ACL Policy](configuration.md#tailscale-tags--acl-policy) setup in the Configuration section. Then either export a tagged auth key for non-interactive setup:

```bash
export TS_AUTHKEY="tskey-auth-..."
```

…or skip this and use interactive browser login in step 3.

`TS_AUTHKEY` is read by the Tailscale sidecar, which the **daemon**
spawns — so it has to be present in the daemon's environment, not just
in the shell you run `dustctl` from. Exporting it before
`dustctl daemon start` works because the daemon inherits your shell's
environment. For a daemon started by the service manager, set it there
instead: an `EnvironmentFile` on the systemd unit, or
`services.dust.environmentFile` on NixOS.

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

## 3. Run the Setup Wizard

`dustctl init` walks you through first-time configuration — it names the
node, unlocks (or creates) the local key store, brings up Tailscale, and
configures the network:

```bash
dustctl init
```

The wizard will:

1. Create the data directory (`~/.dust` by default).
2. Verify the daemon is running, and offer to start it if it is not.
3. Prompt for a **node name**. This is the node's unique short name — it
   becomes the host part of the Erlang node (`dust@<name>`) and the
   suffix of the Tailscale hostname (`dust-node-<name>`), so it must be
   unique across the cluster. Press Enter to keep the current value. The
   Erlang VM reads the name at boot, so a change takes effect on the
   next daemon restart.
4. Prompt for a **key-store passphrase** — on first use this creates a
   new key, on later runs it unlocks the existing one.
5. **Start Tailscale.** Now that the node name is settled, the wizard
   starts the sidecar and waits up to 45 seconds for it to come up. If
   `TS_AUTHKEY` was set in the daemon's environment the node connects on
   its own; otherwise the wizard prints an interactive login URL — open
   it in a browser to authenticate the node.
6. Offer to create a new network (this node becomes the genesis node) or
   join an existing one.

Follow the on-screen prompts to finish setup.

A cold sidecar start can take longer than the wizard waits. If it
reports that Tailscale did not respond in time, or if you did not
finish the browser login while it was running, pick it up with
`dustctl auth` in the next step — nothing is lost.

## 4. Authenticate to Tailscale

Connect the node to Tailscale, or confirm that it already is:

```bash
dustctl auth
```

If the node authenticated during `dustctl init` — via `TS_AUTHKEY`, or
because you completed the browser login while the wizard was waiting —
this command just confirms the connection. Otherwise it prints the
interactive login URL: open it in a browser to complete
authentication, and `dustctl auth` polls until the node is connected.

Once authenticated, `dustctl auth status` shows the node's Tailscale IP and tag:

```bash
dustctl auth status
```

## 5. Adding More Nodes

If you chose "Create a new network" in the wizard, your node is already its own cluster. To add another node, generate an invite token on this node and use it from the new one:

```bash
# On the existing node
dustctl invite

# On the new node (use the IP and token printed above)
dustctl join <IP> <TOKEN>
```

Each new node goes through this same guide first — install, start the
daemon, `dustctl init`, `dustctl auth` — and only then joins with the
token above.

You are now ready to use Dust. See the [CLI Reference](cli.md) for a full list of commands.

## Locking and Unlocking Later

The key store stays unlocked until you explicitly lock it or the daemon restarts. After a restart you'll need to unlock again before performing file operations:

```bash
dustctl unlock   # prompts for the passphrase
dustctl lock     # lock the key store
```
