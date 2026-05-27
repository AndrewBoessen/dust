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
