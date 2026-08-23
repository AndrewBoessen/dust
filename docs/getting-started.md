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

If you chose "Create a new network" in the wizard, your node is already its
own cluster. Adding a second node takes an invite from the existing node.

### On the existing node

The key store must be **unlocked** — the invite hands the joiner the
network's secrets, and a locked node has none to give:

```bash
dustctl unlock   # if the key store is locked
dustctl invite
```

This prints the node's Tailscale IP and a token. The token is
**single-use and expires after 10 minutes**, and locking the key store
invalidates any outstanding tokens. Generate a fresh one if either
happens.

### On the new node

Work through steps 1–4 of this guide on the new machine first — install,
start the daemon, `dustctl init`, `dustctl auth`. The node has to be
connected to Tailscale before it can reach a peer.

At the wizard's last step choose **"Join an existing network"** and paste
the IP and token. If you skipped it, or the token expired, join later with:

```bash
dustctl join <IP> <TOKEN>
```

### What joining actually does

The joining node contacts the peer over Tailscale and adopts two secrets
from it:

- the **OTP cookie**, which makes it a member of the Erlang cluster.
  Without it every peer rejects its handshake with
  `Invalid challenge reply`;
- the **master key**, which unwraps the per-file keys. Without it the node
  cannot read any file the cluster already holds, and the files it writes
  are unreadable to everyone else.

Because `dustctl init` creates a key store (step 3) *before* the join step,
a node that ran the full wizard already minted a master key of its own. The
join therefore asks before replacing it:

```
! This node already holds data encrypted with its own master key

  Stored shards  12
  Files          3

  Joining adopts the network's master key. Data stored under this
  node's current key becomes permanently unreadable.

Adopt the network's master key anyway? [yN]:
```

On a new node there is nothing to lose — answer **yes**. If the node
holds no data at all, the key is adopted without asking. To skip the
prompt in a script, pass `--force`:

```bash
dustctl join <IP> <TOKEN> --force
```

Declining changes nothing: the node keeps its own key and does **not**
join, rather than half-joining with the wrong key.

### Passphrases are per-node

There is no shared "network password". Adopting the master key re-encrypts
it under the passphrase you chose on *that* node, so each node keeps its
own. Unlock each node with its own passphrase.

### Confirm the cluster

From either machine:

```bash
dustctl nodes
```

Both nodes should be listed. It can take up to 15 seconds for peer
discovery to notice a newly joined node.

You are now ready to use Dust. See the [CLI Reference](cli.md) for a full list of commands.

## Locking and Unlocking Later

The key store stays unlocked until you explicitly lock it or the daemon restarts. After a restart you'll need to unlock again before performing file operations:

```bash
dustctl unlock                      # prompts for the passphrase
dustctl unlock --password <PASS>    # non-interactive
dustctl lock                        # lock the key store
```

Locking also stops the node serving secrets to joiners and invalidates any
outstanding invite tokens.

## Troubleshooting

**`dustctl auth` prints "Could not retrieve auth URL"**
The node has not been through `dustctl init` yet. The daemon holds the
Tailscale sidecar back until the node has a name and a key store, so there
is no session to log in to. Run `dustctl init` first — see
[Setup Order](#setup-order).

**The daemon log repeats `** Hostname <name> is illegal **`**
Node names must not contain a dot, and every node in a cluster must run a
version that uses short-name Erlang distribution. Check
[Configuration → Node Names and Erlang Distribution](configuration.md#node-names-and-erlang-distribution).

**The daemon log repeats `Connection attempt from node ... rejected. Invalid challenge reply.`**
The other node never adopted the network's OTP cookie, so it is using one
of its own. Re-run the join on that node.

**Downloads fail but `dustctl ls` lists the files**
The node holds a different master key from the rest of the cluster, so it
cannot unwrap the per-file keys. Re-run the join on that node and accept
the master key replacement.

**`dustctl invite` returns "Unlock the key store before issuing an invite"**
The invite hands over the network's secrets, so the issuing node must be
unlocked. Run `dustctl unlock` and issue a fresh token.

**`dustctl join` reports the key store is locked**
The joining node needs an unlocked key store so the network's master key
can be written under its passphrase. Run `dustctl unlock`, then join again.

**`dustctl help` and `dustctl version`** work with no daemon running, before
`dustctl init`, and before Tailscale is authenticated. If any other command
reports "Not connected to Tailscale", finish [step 4](#4-authenticate-to-tailscale).
