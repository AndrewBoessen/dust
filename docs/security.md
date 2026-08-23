# Security

## Interactive URL Authentication

If you authenticate by visiting the Tailscale login URL (instead of using a `TS_AUTHKEY`), **the authenticating user must be listed in `tagOwners`** for the configured tag. For example, if your policy has:

```json
"tagOwners": { "tag:dust-node": ["alice@example.com"] }
```

Only `alice@example.com` can authenticate and receive the tag. If a different user authenticates, the node joins **without the tag**, which means:

- ACL isolation rules **will not apply** — the node can see and be seen by other tailnet devices.
- Other dust nodes **will not discover it** as a peer (peer discovery filters by tag).
- The sidecar will detect this and **exit with a fatal error** to prevent running untagged.

**Recommendation:** Use a tagged `TS_AUTHKEY` for production. It guarantees the correct tags regardless of who deploys the node.

## Cluster Secrets

A Dust cluster shares two secrets, both handed to a new node when it joins:

| Secret | Purpose | Stored at |
| ------ | ------- | --------- |
| **Erlang OTP cookie** | Authenticates the distribution handshake between nodes | `<persist_dir>/ts_state/dust-node-<name>/secrets.json`, mode `0600` |
| **Master key** | Wraps every per-file key; without it a node cannot read the cluster's files | `<persist_dir>/master.key`, encrypted at rest |

### How they reach a new node

`dustctl invite` puts the issuing node's sidecar into a state where it will
serve these secrets, guarded by a one-time token. The token is
**single-use**, **expires after 10 minutes**, and is invalidated when the
key store locks. The transfer itself runs over the tailnet on the sidecar's
key-exchange port (TCP 9473), so it is confined to tagged Dust nodes by the
ACL policy above.

The issuing node must be unlocked to issue an invite — a locked node has no
master key in memory to serve, so the request is rejected rather than
handing out a dangling token.

### Master key at rest

The master key is never stored in the clear. Each node encrypts it under a
passphrase of its own choosing, so a stolen `master.key` file is useless
without that node's passphrase. There is no shared network password:
adopting the cluster's master key on join re-encrypts it under the local
passphrase.

### Replacing a node's master key

Joining a network replaces the joining node's master key with the
cluster's. Anything that node had already encrypted under its own key
becomes permanently unreadable. `dustctl join` refuses to do this silently
— it reports how much local data is at stake and asks for confirmation,
and it treats "cannot determine" as "data may exist". `--force` skips the
prompt; declining leaves the node untouched and does not join.
