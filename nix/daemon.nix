{ lib
, stdenv
, beamPackages
, fetchFromGitHub
, rustPlatform
, cmake
, gnumake
, pkg-config
, gcc
, git
, rustc
, cargo
, go
, snappy
, openssl
, zlib
, zstd
, lz4
, bzip2
, ncurses
, tsnetSidecar
}:

# Builds the top-level Dust release (`mix release dust`) for NixOS.
#
# Native dependency notes
# ────────────────────────
# * Rust NIFs (`rs_simd`, `disk_space`) use plain Rustler — compiled from
#   source. We vendor their Cargo deps via `importCargoLock`.
# * The hex `rocksdb` package vendors the upstream rocksdb sources but its
#   rebar.config has a `git submodule update --init --recursive` pre_hook
#   that fails in the Nix sandbox (no `.git` dir in a fetched dep). We
#   strip that line.
# * `argon2_elixir` is a `:make` C build — needs gcc + gnumake.
# * The Go tsnet sidecar is built separately in `nix/tsnet-sidecar.nix`
#   and overlaid into `dust_bridge`'s priv dir in `postInstall`.
#
# Hashes are placeholders — replace `lib.fakeHash` with the values
# `nix build` reports on first run.
let
  pname = "dust";
  version = "0.1.2";

  src = ../.;

  # Fixed-output derivation containing the BEAM-fetched hex deps. Patched
  # post-fetch so the rocksdb dep no longer tries to run `git submodule`.
  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "${pname}-mix-deps";
    inherit src version;
    hash = lib.fakeHash;

    # Make `mix deps.get` work in the sandbox.
    env = {
      HEX_OFFLINE = "0";
      MIX_ENV = "prod";
    };

    # Patch the rocksdb dep so the submodule pre_hook is a no-op. The
    # vendored rocksdb sources are already present under
    # `deps/rocksdb/deps/rocksdb/` from the hex tarball.
    postBuild = ''
      if [ -f $out/rocksdb/rebar.config ]; then
        substituteInPlace $out/rocksdb/rebar.config \
          --replace-quiet \
            '{compile, "git submodule update --init --recursive"},' \
            ""
      fi
    '';
  };

  # Vendor the Cargo deps for the two Rust NIFs. Both lockfiles live
  # under deps/ inside `mixFodDeps`. Reading them through the FOD output
  # is IFD, but it means we don't need to commit copies of the lockfiles
  # into the repo — the hex-fetched sources are the source of truth.
  rsSimdCargoVendor = rustPlatform.importCargoLock {
    lockFile = "${mixFodDeps}/rs_simd/native/rs_simd_nif/Cargo.lock";
  };

  diskSpaceCargoVendor = rustPlatform.importCargoLock {
    lockFile = "${mixFodDeps}/disk_space/Cargo.lock";
  };
in
beamPackages.mixRelease {
  inherit pname version src mixFodDeps;

  releaseType = "release";
  mixEnv = "prod";

  nativeBuildInputs = [
    cmake
    gnumake
    pkg-config
    gcc
    git
    rustc
    cargo
    go
  ];

  buildInputs = [
    snappy
    openssl
    zlib
    zstd
    lz4
    bzip2
    ncurses
  ];

  # Wire vendored cargo deps into each NIF's source tree before mix
  # invokes rustler. CARGO_HOME points at a writable scratch dir so
  # cargo's locks/registry don't try to touch $HOME.
  preBuild = ''
    export HOME=$TMPDIR
    export CARGO_HOME=$TMPDIR/cargo
    mkdir -p $CARGO_HOME

    mkdir -p deps/rs_simd/native/rs_simd_nif/.cargo
    cp ${rsSimdCargoVendor}/config.toml deps/rs_simd/native/rs_simd_nif/.cargo/config.toml || true
    ln -sfn ${rsSimdCargoVendor} deps/rs_simd/native/rs_simd_nif/vendor

    mkdir -p deps/disk_space/.cargo
    cp ${diskSpaceCargoVendor}/config.toml deps/disk_space/.cargo/config.toml || true
    ln -sfn ${diskSpaceCargoVendor} deps/disk_space/vendor

    # rocksdb cmake build picks these up via find_package / pkg-config.
    export PKG_CONFIG_PATH="${snappy.dev}/lib/pkgconfig:${openssl.dev}/lib/pkgconfig:$PKG_CONFIG_PATH"
  '';

  # Drop the Go sidecar into the priv dir of the dust_bridge app inside
  # the assembled release so the daemon can find it at runtime.
  postInstall = ''
    bridgePriv=$(find $out/lib -maxdepth 2 -type d -name 'dust_bridge-*' -print -quit)/priv
    mkdir -p "$bridgePriv"
    cp ${tsnetSidecar}/bin/tsnet_sidecar "$bridgePriv/tsnet_sidecar"
    chmod +x "$bridgePriv/tsnet_sidecar"
  '';

  meta = with lib; {
    description = "Dust distributed file system daemon";
    homepage = "https://github.com/AndrewBoessen/dust";
    license = licenses.asl20;
    platforms = platforms.unix;
    mainProgram = "dust";
  };
}
