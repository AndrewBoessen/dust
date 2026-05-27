{ lib
, buildGoModule
, go
}:

# Builds the Tailscale `tsnet` sidecar that the Dust daemon spawns as a
# separate OS process. The daemon's `dust_bridge` app expects the binary
# in its priv directory; the consumer derivation (daemon.nix) is
# responsible for placing it there.
#
# `vendorHash` is left as `lib.fakeHash` so the first `nix build` prints
# the real hash to substitute in. Rebuild whenever go.sum changes.
buildGoModule {
  pname = "dust-tsnet-sidecar";
  version = "0.1.5";

  src = ../apps/dust_bridge/native/tsnet_sidecar;

  # Replace with the hash printed by `nix build` on first run.
  vendorHash = "sha256-iOTgl8BZkLYqSa/Dm4QSDMGSaOMXtnmJ8TbmN6GyFfw=";

  # tsnet doesn't need CGO; matches the Windows build instruction in README.
  env.CGO_ENABLED = "0";

  # The Go binary is consumed by the daemon, not installed as a top-level
  # tool. We keep $out/bin/tsnet_sidecar so the daemon derivation can
  # symlink/copy from a stable path.
  inherit go;

  meta = with lib; {
    description = "Tailscale tsnet sidecar for the Dust daemon";
    license = licenses.asl20;
    platforms = platforms.unix ++ platforms.windows;
  };
}
